import AppKit
import ShrinkCore
import SwiftUI
import ZipCore

// MARK: - 상태

/// 용량 줄이기 한 번의 흐름: 검사 → 보고서(단계·종류 고르기) → 줄이기 → 완료
@MainActor
public final class ShrinkModel: ObservableObject {
    enum Phase {
        case scanning
        case ready(Shrink.Report)
        case working(Shrink.Report)
        case done(Shrink.Report, Shrink.Outcome)
        case failed(String, retry: Shrink.Report?)
    }

    let urls: [URL]
    @Published var phase: Phase = .scanning
    @Published var enabled: Set<Shrink.Kind> = Set(Shrink.Kind.allCases)
    @Published var level: Shrink.Level = .medium
    @Published var fraction: Double = 0
    @Published var currentName = ""
    private var cancel = CancelToken()

    init(urls: [URL]) {
        self.urls = urls
    }

    var title: String {
        urls.count == 1 ? urls[0].lastPathComponent.precomposedStringWithCanonicalMapping : "항목 \(urls.count)개"
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
            let result = Result { try Shrink.scan(urls, cancel: token) }
            await MainActor.run {
                switch result {
                case .success(let report): self.phase = .ready(report)
                case .failure(let error): self.phase = .failed(error.localizedDescription, retry: nil)
                }
            }
        }
    }

    func run(_ report: Shrink.Report, mode: SendPrep.Mode) {
        if mode == .inPlace && !confirmInPlace() { return }
        let kinds = enabled.intersection(report.kinds)
        let level = level
        cancel = CancelToken()
        let token = cancel
        fraction = 0
        currentName = ""
        phase = .working(report)
        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try Shrink.apply(report, kinds: kinds, level: level, mode: mode, progress: { f, name in
                    Task { @MainActor in
                        self.fraction = f
                        if !name.isEmpty { self.currentName = name }
                    }
                }, cancel: token)
                await MainActor.run { self.phase = .done(report, outcome) }
            } catch ZipError.cancelled {
                await MainActor.run { self.phase = .ready(report) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription, retry: report) }
            }
        }
    }

    func stop() { cancel.cancel() }

    private func confirmInPlace() -> Bool {
        let alert = NSAlert()
        alert.messageText = "원본을 줄인 파일로 바꿀까요?"
        alert.informativeText = "원래 파일은 휴지통으로 옮겨요. 영상은 MP4, TIFF·BMP는 JPG, 무손실 소리는 M4A로 바뀌어요."
        alert.addButton(withTitle: "원본 바꾸기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - 문구

extension Shrink.Kind {
    var title: String {
        switch self {
        case .photo: return "사진"
        case .video: return "영상"
        case .pdf: return "PDF"
        case .audio: return "소리"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        }
    }

    func how(_ level: Shrink.Level) -> String {
        switch self {
        case .photo: return "\(level.photoLabel)로 줄여요"
        case .video: return "\(level.videoLabel) MP4로 다시 만들어요"
        case .pdf: return "안의 이미지를 줄여요"
        case .audio: return "AAC \(level.audioLabel) M4A로 바꿔요"
        }
    }
}

extension Shrink.Level {
    var title: String { ["조금", "적당히", "많이"][rawValue] }
    var caption: String {
        ["화질을 거의 그대로 두고 덜어내요", "메일·메신저로 보내기 좋게 줄여요", "화면으로 볼 정도로 크게 줄여요"][rawValue]
    }
}

// MARK: - 화면

struct ShrinkScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let shrink = model.shrink {
            ShrinkFlow(shrink: shrink, model: model)
        } else {
            ToolDropWell(model: model, targetedSymbol: "arrow.down.right.and.arrow.up.left",
                         targetedTitle: "놓으면 크기를 재요",
                         title: "용량을 줄일 파일을 놓으세요") {
                ShrinkGlyph(size: 64)
            }
        }
    }
}

struct ShrinkFlow: View {
    @ObservedObject var shrink: ShrinkModel
    @ObservedObject var model: AppModel

    var body: some View {
        switch shrink.phase {
        case .scanning:
            ToolHeader(title: shrink.title, subtitle: "크기를 재는 중…", isFolder: isFolder) {}
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80).card()
        case .ready(let report):
            ShrinkReportView(shrink: shrink, model: model, report: report)
        case .working:
            ToolHeader(title: shrink.title, subtitle: "줄이는 중… \(Int(shrink.fraction * 100))%", isFolder: isFolder) {}
            VStack(alignment: .leading, spacing: 10) {
                ProgressBar(value: shrink.fraction)
                HStack {
                    Text(shrink.currentName.isEmpty ? " " : shrink.currentName)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("멈추기") { shrink.stop() }.controlSize(.small)
                }
            }
            .padding(16)
            .card()
        case .done(_, let outcome):
            ShrinkDoneCard(model: model, outcome: outcome)
        case .failed(let message, let retry):
            ToolFailureCard(title: "줄이지 못했어요", message: message) {
                Button("처음으로") { model.shrink = nil }
                if let retry {
                    Button("보고서로 돌아가기") { shrink.phase = .ready(retry) }
                } else {
                    Button("다시 재기") { shrink.scan() }
                }
            }
        }
    }

    private var isFolder: Bool {
        (try? shrink.urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false || shrink.urls.count > 1
    }
}

struct ShrinkReportView: View {
    @ObservedObject var shrink: ShrinkModel
    @ObservedObject var model: AppModel
    let report: Shrink.Report

    private var chosen: Set<Shrink.Kind> { shrink.enabled.intersection(report.kinds) }
    private var isFolder: Bool {
        (try? shrink.urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false || shrink.urls.count > 1
    }

    var body: some View {
        ToolHeader(title: shrink.title, subtitle: "파일 \(report.fileCount)개 · \(Fmt.bytes(report.totalBytes))", isFolder: isFolder) {
            IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.shrink = nil }
        }

        if report.items.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.success)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("줄일 파일이 없어요").font(.headline)
                    Text("사진, 영상, PDF, 무손실 음원(WAV·FLAC·ALAC 등)을 넣어 보세요")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("줄이는 정도", selection: $shrink.level) {
                    ForEach(Shrink.Level.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(shrink.level.caption).font(.callout).foregroundStyle(.secondary)
                EstimateBar(before: report.totalBytes,
                            after: report.estimatedTotal(kinds: chosen, level: shrink.level))
            }
            .padding(14)
            .card()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(report.kinds.enumerated()), id: \.element) { i, kind in
                        if i > 0 { Divider().padding(.leading, 50) }
                        KindCard(kind: kind, items: report.items(of: kind), level: shrink.level, isOn: Binding(
                            get: { shrink.enabled.contains(kind) },
                            set: { on in if on { shrink.enabled.insert(kind) } else { shrink.enabled.remove(kind) } }
                        ))
                    }
                }
                .card()
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        shrink.run(report, mode: .inPlace)
                    } label: {
                        Text("원본 바꾸기").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .help("줄인 파일로 바꾸고, 원래 파일은 휴지통으로 옮겨요")

                    Button {
                        shrink.run(report, mode: .copy)
                    } label: {
                        Text("복사본 만들기").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .tint(Theme.accent)
                    .help("‘용량 줄인 파일’ 폴더에 줄인 복사본을 만들어요. 원본은 그대로예요")
                }
                .controlSize(.large)
                .disabled(chosen.isEmpty)
                if chosen.isEmpty {
                    Text("줄일 종류를 하나 이상 켜 주세요")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}

/// "205 MB → 약 18 MB" 와 줄어드는 비율 막대
struct EstimateBar: View {
    let before: UInt64
    let after: UInt64

    private var ratio: Double { before == 0 ? 1 : Double(after) / Double(before) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(before)).font(.body).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text("약 \(Fmt.bytes(after))").font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                Spacer()
                if ratio < 0.99 {
                    Text("\(Int(((1 - ratio) * 100).rounded()))% 줄어요").font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.success)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(Theme.sky).frame(width: max(6, geo.size.width * min(max(ratio, 0), 1)))
                }
            }
            .frame(height: 6)
            .animation(.snappy(duration: 0.25), value: ratio)
        }
        .accessibilityElement(children: .combine)
    }
}

struct KindCard: View {
    let kind: Shrink.Kind
    let items: [Shrink.Item]
    let level: Shrink.Level
    @Binding var isOn: Bool
    @State private var expanded = false

    private var before: UInt64 { items.reduce(0) { $0 + $1.size } }
    private var after: UInt64 { items.reduce(0) { $0 + $1.estimate(level) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isOn ? Theme.accent : .secondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.headline)
                    Text("\(kind.how(level)) · 약 \(Fmt.bytes(after))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                DisclosureCount(count: items.count, expanded: $expanded)
                Toggle(kind.title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((item.path as NSString).lastPathComponent)
                                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.bytes(item.size)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .help(item.path)
                    }
                }
                .padding(.leading, 36)
                .opacity(isOn ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct ShrinkDoneCard: View {
    @ObservedObject var model: AppModel
    let outcome: Shrink.Outcome

    private var result: URL? {
        if let folder = outcome.folder { return folder }
        guard let first = outcome.items.first else { return nil }
        return FileManager.default.fileExists(atPath: first.path) ? first : first.deletingLastPathComponent()
    }

    private var saved: Int {
        outcome.before == 0 ? 0 : Int(((1 - Double(outcome.after) / Double(outcome.before)) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.success)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome.shrunk > 0 ? "용량을 줄였어요" : "줄일 수 있는 게 없었어요").font(.headline)
                    Text("\(Fmt.bytes(outcome.before)) → \(Fmt.bytes(outcome.after))" + (saved > 0 ? " · \(saved)% 줄었어요" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                    if outcome.kept > 0 {
                        Text("더 작아지지 않는 파일 \(outcome.kept)개는 그대로 뒀어요")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !outcome.trashed.isEmpty {
                        Text("원래 파일 \(outcome.trashed.count)개는 휴지통에 있어요")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.shrink = nil }
            }

            if let result {
                ResultChip(url: result, isZip: false)
                HStack(spacing: 8) {
                    Button {
                        model.reveal(result)
                    } label: {
                        Label("Finder에서 보기", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .tint(Theme.accent)
                    .controlSize(.large)

                    ShareLink(item: result) {
                        Label("공유…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.large)
                }
            }

            if !outcome.failed.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("줄이지 못한 파일 \(outcome.failed.count)개 (원래대로 담았어요)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning)
                    ForEach(outcome.failed.prefix(3), id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(16)
        .card()
    }
}

/// 용량 줄이기 그림: 큰 사각형이 작은 사각형으로 줄어드는 모양
struct ShrinkGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .strokeBorder(Theme.sky.opacity(0.45), style: StrokeStyle(lineWidth: size * 0.04, dash: [size * 0.08, size * 0.06]))
                .frame(width: size * 0.86, height: size * 0.86)
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .fill(LinearGradient(colors: [Theme.sky.opacity(0.55), Theme.sky], startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: size * 0.46, height: size * 0.46)
            Image(systemName: "arrow.down.left")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(.primary)
                .offset(x: size * 0.5, y: -size * 0.5)
        }
        .frame(width: size, height: size, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}
