import AppKit
import SwiftUI
import ZipCore

// MARK: - 상태

/// "Windows로 보낼 준비" 한 번의 흐름: 검사 → 보고서(고칠 것 고르기) → 고치기 → 완료
@MainActor
public final class PrepModel: ObservableObject {
    enum Phase {
        case scanning
        case ready(SendPrep.Report)
        case working(SendPrep.Report)
        case done(SendPrep.Report, SendPrep.Outcome, zip: URL?)
        case failed(String, retry: SendPrep.Report?)
    }

    let urls: [URL]
    let settings: AppSettings
    @Published var phase: Phase = .scanning
    @Published var enabled: Set<SendPrep.Fix> = Set(SendPrep.Fix.allCases)
    @Published var fraction: Double = 0
    @Published var currentName = ""
    @Published var zipping = false
    private var cancel = CancelToken()

    init(urls: [URL], settings: AppSettings) {
        self.urls = urls
        self.settings = settings
    }

    var title: String {
        urls.count == 1 ? SendPrep.displayName(urls[0]) : "항목 \(urls.count)개"
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .working: return true
        default: return false
        }
    }

    func scan() {
        phase = .scanning
        let urls = urls
        let token = cancel
        Task.detached(priority: .userInitiated) {
            let result = Result { try SendPrep.scan(urls, cancel: token) }
            await MainActor.run {
                switch result {
                case .success(let report):
                    self.enabled = report.fixable
                    self.phase = .ready(report)
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription, retry: nil)
                }
            }
        }
    }

    /// 원본 고치기는 한 번 더 묻는다
    func run(_ report: SendPrep.Report, mode: SendPrep.Mode) {
        if mode == .inPlace && !confirmInPlace(report) { return }
        let fixes = enabled.intersection(report.fixable)
        let makeZip = settings.prepMakeZip
        let zipOptions = settings.zipOptions()
        cancel = CancelToken()
        let token = cancel
        fraction = 0
        currentName = ""
        zipping = false
        phase = .working(report)
        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try SendPrep.apply(report, fixes: fixes, mode: mode, progress: { f, name in
                    Task { @MainActor in
                        self.fraction = makeZip ? f * 0.6 : f
                        self.currentName = name
                    }
                }, cancel: token)
                var zip: URL?
                if makeZip, !outcome.items.isEmpty {
                    await MainActor.run { self.zipping = true }
                    let target = ZipWriter.suggestedOutputURL(for: outcome.items)
                    try ZipWriter.compress(outcome.items, to: target, options: zipOptions, progress: { f, _ in
                        Task { @MainActor in self.fraction = 0.6 + 0.4 * f }
                    }, cancel: token)
                    zip = target
                }
                let finished = zip
                await MainActor.run { self.phase = .done(report, outcome, zip: finished) }
            } catch ZipError.cancelled {
                await MainActor.run { self.phase = .ready(report) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription, retry: report) }
            }
        }
    }

    func stop() { cancel.cancel() }

    private func confirmInPlace(_ report: SendPrep.Report) -> Bool {
        let alert = NSAlert()
        alert.messageText = "원본 파일을 고칠까요?"
        var lines = ["고른 파일의 이름을 직접 바꿔요."]
        let fixes = enabled.intersection(report.fixable)
        if fixes.contains(.junk) { lines.append("Mac 숨김 파일은 휴지통으로 옮겨요.") }
        if fixes.contains(.heic) { lines.append("HEIC 사진은 JPG로 바꾸고 원본은 휴지통으로 옮겨요.") }
        if fixes.contains(.csv) { lines.append("CSV 파일 맨 앞에 한글 표시(BOM)를 붙여요.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "원본 고치기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension SendPrep {
    /// URL은 한글을 자모로 풀어 주므로 화면에 보일 때는 다시 붙인다
    static func displayName(_ url: URL) -> String {
        url.lastPathComponent.precomposedStringWithCanonicalMapping
    }
}

// MARK: - 문구

extension SendPrep.Fix {
    var title: String {
        switch self {
        case .names: return "이름 고치기"
        case .junk: return "Mac 숨김 파일 빼기"
        case .csv: return "CSV 엑셀 깨짐 막기"
        case .heic: return "HEIC 사진을 JPG로"
        }
    }

    var detail: String {
        switch self {
        case .names: return "풀린 한글 자모, 못 쓰는 글자, 겹치는 이름"
        case .junk: return ".DS_Store, ._파일처럼 Windows에 필요 없는 파일"
        case .csv: return "한글 표시(BOM)를 붙여 엑셀이 바로 읽게 해요"
        case .heic: return "Windows 기본 사진 앱에서도 열려요"
        }
    }

    var symbol: String {
        switch self {
        case .names: return "character.textbox"
        case .junk: return "eye.slash"
        case .csv: return "tablecells"
        case .heic: return "photo"
        }
    }
}

extension SendPrep.IssueKind {
    var reason: String {
        switch self {
        case .decomposed: return "한글 자모가 풀린 이름"
        case .forbiddenChars: return "Windows에서 못 쓰는 글자"
        case .reservedName: return "Windows가 예약한 이름"
        case .trailingDotSpace: return "끝에 붙은 점이나 공백"
        case .duplicateName: return "Windows에서는 겹치는 이름"
        case .junk: return "Mac 숨김 파일"
        case .csvWithoutBOM: return "엑셀에서 한글이 깨져요"
        case .heic: return "HEIC 사진"
        case .macOnlyDocument: return "Mac 전용 문서예요. PDF나 Office 형식으로 내보내 주세요"
        case .macShortcut: return "Mac 인터넷 바로가기라 Windows에서 안 열려요"
        case .macApp: return "Mac 앱이라 Windows에서 실행할 수 없어요"
        case .macInstaller: return "Mac 설치 파일이라 Windows에서 쓸 수 없어요"
        case .alias: return "Mac 가상본이라 Windows에서 안 열려요"
        case .symlink: return "링크라서 Windows에서 안 열릴 수 있어요"
        case .longPath: return "경로가 너무 길어 Windows에서 안 열릴 수 있어요"
        }
    }
}

// MARK: - 화면

struct PrepScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let prep = model.prep {
            PrepFlow(prep: prep, model: model)
        } else {
            ToolDropWell(model: model, targetedSymbol: "wand.and.stars", targetedTitle: "놓으면 검사해요",
                         title: "Windows로 보낼 파일을 놓으세요",
                         subtitle: "받는 사람 컴퓨터에서 깨지지 않게 미리 고쳐요") {
                WandGlyph(size: 64)
            }
            ChecksCard(title: "이런 걸 검사해요", rows: [
                ("character.textbox", "한글 이름", "자모가 풀린 이름, 못 쓰는 글자, 겹치는 이름"),
                ("tablecells", "CSV 파일", "엑셀에서 한글이 깨지지 않게"),
                ("photo", "HEIC 사진", "어디서나 열리는 JPG로"),
                ("exclamationmark.triangle", "열 수 없는 파일", "Mac 전용 문서, 바로가기, 너무 긴 경로"),
            ])
        }
    }
}

struct PrepFlow: View {
    @ObservedObject var prep: PrepModel
    @ObservedObject var model: AppModel

    var body: some View {
        switch prep.phase {
        case .scanning:
            PrepHeader(prep: prep, model: model, subtitle: "검사하는 중…", closable: false)
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80).card()
        case .ready(let report):
            PrepReportView(prep: prep, model: model, report: report)
        case .working:
            PrepHeader(prep: prep, model: model, subtitle: prep.zipping ? "ZIP으로 묶는 중…" : "고치는 중…", closable: false)
            VStack(alignment: .leading, spacing: 10) {
                ProgressBar(value: prep.fraction)
                HStack {
                    Text(prep.currentName.isEmpty ? " " : prep.currentName)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("멈추기") { prep.stop() }.controlSize(.small)
                }
            }
            .padding(16)
            .card()
        case .done(let report, let outcome, let zip):
            PrepDoneCard(prep: prep, model: model, report: report, outcome: outcome, zip: zip)
        case .failed(let message, let retry):
            ToolFailureCard(title: "준비하지 못했어요", message: message) {
                Button("처음으로") { model.prep = nil }
                if let retry {
                    Button("보고서로 돌아가기") { prep.phase = .ready(retry) }
                } else {
                    Button("다시 검사") { prep.scan() }
                }
            }
        }
    }
}

struct PrepHeader: View {
    @ObservedObject var prep: PrepModel
    @ObservedObject var model: AppModel
    let subtitle: String
    var closable = true

    var body: some View {
        ToolHeader(title: prep.title, subtitle: subtitle, isFolder: prep.urls.count > 1 || isFolder) {
            if closable {
                IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.prep = nil }
            }
        }
    }

    private var isFolder: Bool {
        (try? prep.urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// MARK: 보고서

struct PrepReportView: View {
    @ObservedObject var prep: PrepModel
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let report: SendPrep.Report

    init(prep: PrepModel, model: AppModel, report: SendPrep.Report) {
        self.prep = prep
        self.model = model
        self.settings = model.settings
        self.report = report
    }

    private var fixes: [SendPrep.Fix] { SendPrep.Fix.allCases.filter { report.fixable.contains($0) } }
    private var chosen: Set<SendPrep.Fix> { prep.enabled.intersection(report.fixable) }

    var body: some View {
        PrepHeader(prep: prep, model: model, subtitle: summary)

        ScrollView {
            VStack(spacing: 10) {
                if fixes.isEmpty {
                    allGood
                }
                ForEach(fixes) { fix in
                    FixCard(fix: fix, issues: report.issues(for: fix), isOn: Binding(
                        get: { prep.enabled.contains(fix) },
                        set: { on in if on { prep.enabled.insert(fix) } else { prep.enabled.remove(fix) } }
                    ))
                }
                if !report.warnings.isEmpty {
                    WarningCard(issues: report.warnings)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 12) {
            Toggle("다 하면 ZIP으로 묶기", isOn: $settings.prepMakeZip)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            if fixes.isEmpty {
                Button {
                    model.compressNow(prep.urls)
                    model.settings.tab = .zip
                    model.prep = nil
                } label: {
                    Label("바로 ZIP으로 묶기", systemImage: "doc.zipper").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.primary).controlSize(.large)
            } else {
                HStack(spacing: 8) {
                    Button {
                        prep.run(report, mode: .inPlace)
                    } label: {
                        Text("원본 고치기").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("고른 파일의 이름을 직접 바꿔요. 지우는 파일은 휴지통으로 옮겨요")

                    Button {
                        prep.run(report, mode: .copy)
                    } label: {
                        Text("복사본 만들기").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .help("‘Windows로 보낼 파일’ 폴더에 고친 복사본을 만들어요. 원본은 그대로예요")
                }
                .controlSize(.large)
                .disabled(chosen.isEmpty)
                Text(chosen.isEmpty ? "고칠 항목을 하나 이상 켜 주세요"
                                    : "복사본은 원본 옆 ‘Windows로 보낼 파일’ 폴더에 만들어요")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var summary: String {
        var parts = ["파일 \(report.fileCount)개"]
        let fixCount = Set(report.issues.filter { $0.kind.fix != nil }.map(\.path)).count
        parts.append(fixCount == 0 ? "고칠 것 없음" : "고칠 것 \(fixCount)개")
        if !report.warnings.isEmpty { parts.append("확인할 것 \(report.warnings.count)개") }
        return parts.joined(separator: " · ")
    }

    private var allGood: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.success)
                .frame(width: 36, height: 36).background(Theme.success.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("고칠 게 없어요").font(.system(size: 14, weight: .bold))
                Text(report.warnings.isEmpty ? "이대로 Windows로 보내도 괜찮아요" : "아래 항목만 확인해 주세요")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .card()
    }
}

struct FixCard: View {
    let fix: SendPrep.Fix
    let issues: [SendPrep.Issue]
    @Binding var isOn: Bool
    @State private var expanded = false

    /// 한 파일에 문제가 여럿이면(예: 자모 분리 + 못 쓰는 글자) 한 줄로 합친다
    private var rows: [(path: String, after: String?, reasons: [String])] {
        var order: [String] = []
        var map: [String: (String?, [String])] = [:]
        for issue in issues {
            if map[issue.path] == nil { order.append(issue.path); map[issue.path] = (issue.after, []) }
            map[issue.path]?.1.append(issue.kind.reason)
        }
        return order.map { ($0, map[$0]?.0, map[$0]?.1 ?? []) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: fix.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Theme.primary : .secondary)
                    .frame(width: 30, height: 30)
                    .background((isOn ? Theme.sky.opacity(0.14) : Color.primary.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(fix.title).font(.system(size: 13, weight: .semibold))
                        Text("\(rows.count)").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.sky.opacity(0.14), in: Capsule())
                    }
                    Text(fix.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle(fix.title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(rows.prefix(expanded ? rows.count : 3).enumerated()), id: \.offset) { _, row in
                    IssueRow(path: row.path, after: row.after, reason: row.reasons.joined(separator: " · "))
                }
                if rows.count > 3 {
                    Button(expanded ? "접기" : "모두 보기 (\(rows.count))") { expanded.toggle() }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.leading, 42)
            .opacity(isOn ? 1 : 0.5)
        }
        .padding(14)
        .card(radius: 12)
    }
}

struct IssueRow: View {
    let path: String
    let after: String?
    let reason: String

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let after, after != name {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Text(after).foregroundStyle(Theme.primary).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 12, weight: .medium))
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .help(path)
    }
}

struct WarningCard: View {
    let issues: [SendPrep.Issue]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 30, height: 30)
                    .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Windows에서 열리지 않을 수 있어요").font(.system(size: 13, weight: .semibold))
                    Text("자동으로 고칠 수 없어서 알려만 드려요").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(issues.prefix(expanded ? issues.count : 3).enumerated()), id: \.offset) { _, issue in
                    IssueRow(path: issue.path, after: nil, reason: issue.kind.reason)
                }
                if issues.count > 3 {
                    Button(expanded ? "접기" : "모두 보기 (\(issues.count))") { expanded.toggle() }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.leading, 42)
        }
        .padding(14)
        .card(radius: 12, border: Theme.warning.opacity(0.35))
    }
}

// MARK: 완료

struct PrepDoneCard: View {
    @ObservedObject var prep: PrepModel
    @ObservedObject var model: AppModel
    let report: SendPrep.Report
    let outcome: SendPrep.Outcome
    let zip: URL?

    private var result: URL? { zip ?? outcome.folder ?? outcome.items.first }

    private var lines: [String] {
        var out: [String] = []
        if outcome.renamed > 0 { out.append("이름 \(outcome.renamed)개 고침") }
        if outcome.removed > 0 { out.append("숨김 파일 \(outcome.removed)개 뺌") }
        if outcome.bomAdded > 0 { out.append("CSV \(outcome.bomAdded)개 엑셀용으로") }
        if outcome.converted > 0 { out.append("사진 \(outcome.converted)장 JPG로") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.success)
                    .frame(width: 36, height: 36).background(Theme.success.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Windows로 보낼 준비가 끝났어요").font(.system(size: 14, weight: .bold))
                    Text(lines.isEmpty ? "바꾼 것은 없어요" : lines.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !outcome.trashed.isEmpty {
                        Text("바꾸기 전 파일 \(outcome.trashed.count)개는 휴지통에 있어요")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.prep = nil }
            }

            if let result {
                ResultChip(url: result, isZip: zip != nil)
                HStack(spacing: 8) {
                    Button {
                        model.reveal(result)
                    } label: {
                        Label("Finder에서 보기", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .controlSize(.large)

                    ShareLink(item: result) {
                        Label("공유…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            if !report.warnings.isEmpty {
                Label("확인할 파일 \(report.warnings.count)개는 그대로 두었어요", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
        }
        .padding(16)
        .card()
    }
}

/// 앱 아이콘과 같은 마법봉 (하늘색 막대 + 검은 끝 + 별)
struct WandGlyph: View {
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, area in
            let s = area.width / 100
            let ink: Color = scheme == .dark ? .white : Color(white: 0.03)
            func bar(_ cx: CGFloat, _ cy: CGFloat, _ length: CGFloat, _ w: CGFloat) -> Path {
                let rect = CGRect(x: -w / 2 * s, y: -length / 2 * s, width: w * s, height: length * s)
                return Path(roundedRect: rect, cornerRadius: w / 2 * s)
                    .applying(CGAffineTransform(rotationAngle: .pi / 4))
                    .applying(CGAffineTransform(translationX: cx * s, y: cy * s))
            }
            func star(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                var p = Path()
                let c = CGPoint(x: cx * s, y: cy * s), r = r * s
                p.move(to: CGPoint(x: c.x, y: c.y - r))
                p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
                p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
                return p
            }
            ctx.fill(bar(40, 62, 56.6, 11), with: .linearGradient(
                Gradient(colors: [Theme.sky.opacity(0.4), Theme.sky]),
                startPoint: CGPoint(x: 20 * s, y: 82 * s), endPoint: CGPoint(x: 48 * s, y: 54 * s)))
            ctx.fill(bar(55, 47, 19.5, 11), with: .color(ink))
            ctx.fill(star(68, 32, 17), with: .color(ink))
            ctx.fill(star(36, 26, 7), with: .color(ink.opacity(0.7)))
            ctx.fill(star(82, 58, 5.5), with: .color(ink.opacity(0.7)))
            ctx.fill(star(84, 20, 3.5), with: .color(ink.opacity(0.7)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
