import AppKit
import ConvertCore
import SwiftUI
import ZipCore

// MARK: - 상태

/// 사진 형식 바꾸기 한 번의 흐름: 찾기 → 형식 고르기 → 바꾸기 → 완료
@MainActor
public final class ConvertModel: ObservableObject {
    enum Phase {
        case scanning
        case ready([Convert.Item])
        case working([Convert.Item])
        case done(Convert.Outcome)
        case failed(String, retry: [Convert.Item]?)
    }

    let urls: [URL]
    let settings: AppSettings
    @Published var phase: Phase = .scanning
    @Published var fraction: Double = 0
    @Published var currentName = ""
    private var cancel = CancelToken()

    init(urls: [URL], settings: AppSettings) {
        self.urls = urls
        self.settings = settings
    }

    var title: String {
        urls.count == 1 ? urls[0].lastPathComponent.precomposedStringWithCanonicalMapping : "항목 \(urls.count)개"
    }

    var isFolder: Bool {
        urls.count > 1 || ((try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
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
            let result = Result { try Convert.scan(urls, cancel: token) }
            await MainActor.run {
                switch result {
                case .success(let items): self.phase = .ready(items)
                case .failure(let error): self.phase = .failed(error.localizedDescription, retry: nil)
                }
            }
        }
    }

    func run(_ items: [Convert.Item]) {
        let format = settings.convertFormat
        let urls = urls
        cancel = CancelToken()
        let token = cancel
        fraction = 0
        currentName = ""
        phase = .working(items)
        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try Convert.apply(items, roots: urls, to: format, progress: { f, name in
                    Task { @MainActor in
                        self.fraction = f
                        if !name.isEmpty { self.currentName = name }
                    }
                }, cancel: token)
                await MainActor.run { self.phase = .done(outcome) }
            } catch ZipError.cancelled {
                await MainActor.run { self.phase = .ready(items) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription, retry: items) }
            }
        }
    }

    func stop() { cancel.cancel() }
}

extension Convert.Format {
    var caption: String {
        switch self {
        case .jpg: return "어디서나 열려요. 투명한 부분은 흰색이 돼요"
        case .png: return "화질 손실 없이, 투명한 배경을 지켜요"
        case .heic: return "JPG 절반쯤 크기. Apple 기기에서 쓰기 좋아요"
        case .webp: return "웹에 올리기 좋은 작은 크기예요"
        case .avif: return "가장 작은 크기. 최신 브라우저와 앱에서 열려요"
        case .tiff: return "인쇄·편집용 무손실. 크기가 커요"
        }
    }
}

// MARK: - 화면

struct ConvertScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let convert = model.convert {
            ConvertFlow(convert: convert, model: model)
        } else {
            ToolDropWell(model: model, targetedSymbol: "arrow.triangle.2.circlepath", targetedTitle: "놓으면 사진을 찾아요",
                         title: "형식을 바꿀 사진을 놓으세요") {
                ConvertGlyph(size: 64)
            }
        }
    }
}

struct ConvertFlow: View {
    @ObservedObject var convert: ConvertModel
    @ObservedObject var model: AppModel

    var body: some View {
        switch convert.phase {
        case .scanning:
            ToolHeader(title: convert.title, subtitle: "사진을 찾는 중…", isFolder: convert.isFolder) {}
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80).card()
        case .ready(let items):
            ConvertReportView(convert: convert, model: model, items: items)
        case .working(let items):
            ToolHeader(title: convert.title, subtitle: "바꾸는 중… \(Int(convert.fraction * 100))%", isFolder: convert.isFolder) {}
            VStack(alignment: .leading, spacing: 10) {
                ProgressBar(value: convert.fraction)
                HStack {
                    Text(convert.currentName.isEmpty ? "사진 \(items.count)장" : convert.currentName)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("멈추기") { convert.stop() }.controlSize(.small)
                }
            }
            .padding(16)
            .card()
        case .done(let outcome):
            ConvertDoneCard(model: model, outcome: outcome, format: model.settings.convertFormat)
        case .failed(let message, let retry):
            ToolFailureCard(title: "바꾸지 못했어요", message: message) {
                Button("처음으로") { model.convert = nil }
                if let retry {
                    Button("다시 해 보기") { convert.phase = .ready(retry) }
                } else {
                    Button("다시 찾기") { convert.scan() }
                }
            }
        }
    }
}

struct ConvertReportView: View {
    @ObservedObject var convert: ConvertModel
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let items: [Convert.Item]
    @State private var expanded = false

    init(convert: ConvertModel, model: AppModel, items: [Convert.Item]) {
        self.convert = convert
        self.model = model
        self.settings = model.settings
        self.items = items
    }

    /// "HEIC 4 · PNG 2 · SVG 1"
    private var kinds: String {
        var counts: [String: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    var body: some View {
        let total = items.reduce(UInt64(0)) { $0 + $1.size }
        ToolHeader(title: convert.title,
                   subtitle: items.isEmpty ? "바꿀 수 있는 사진이 없어요" : "사진 \(items.count)장 · \(Fmt.bytes(total))",
                   isFolder: convert.isFolder) {
            IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.convert = nil }
        }

        if items.isEmpty {
            Text("JPG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP, SVG를 바꿀 수 있어요")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("바꿀 형식", selection: $settings.convertFormat) {
                    ForEach(Convert.Format.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.convertFormat.caption).font(.callout).foregroundStyle(.secondary)
            }
            .padding(14)
            .card()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(kinds).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    DisclosureCount(count: items.count, expanded: $expanded)
                }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(items) { item in
                                HStack {
                                    Text(item.shown).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(Fmt.bytes(item.size)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .card()

            Button {
                convert.run(items)
            } label: {
                Text("\(settings.convertFormat.title)로 바꾸기").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .tint(Theme.accent)
            .controlSize(.large)
            .help("‘형식 바꾼 사진’ 폴더에 새로 만들어요. 원본은 그대로예요")
        }
    }
}

struct ConvertDoneCard: View {
    @ObservedObject var model: AppModel
    let outcome: Convert.Outcome
    let format: Convert.Format

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.success)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(format.title)로 바꿨어요").font(.headline)
                    Text("사진 \(outcome.made + outcome.same)장 · \(Fmt.bytes(outcome.before)) → \(Fmt.bytes(outcome.after))")
                        .font(.callout).foregroundStyle(.secondary)
                    if outcome.same > 0 {
                        Text("이미 \(format.title)인 \(outcome.same)장은 그대로 담았어요")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "처음으로", filled: true) { model.convert = nil }
            }

            if let folder = outcome.folder {
                ResultChip(url: folder, isZip: false)
                HStack(spacing: 8) {
                    Button {
                        model.reveal(folder)
                    } label: {
                        Label("Finder에서 보기", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .tint(Theme.accent)
                    .controlSize(.large)

                    ShareLink(item: folder) {
                        Label("공유…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.large)
                }
            }

            if !outcome.failed.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("바꾸지 못한 사진 \(outcome.failed.count)장", systemImage: "exclamationmark.triangle")
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

/// 형식 바꾸기 그림: 겹친 사진 두 장 사이를 도는 화살표
struct ConvertGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(Theme.skyLight.opacity(0.55))
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(x: -size * 0.14, y: -size * 0.12)
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(LinearGradient(colors: [Theme.sky.opacity(0.7), Theme.sky], startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(x: size * 0.14, y: size * 0.12)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.14, y: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
