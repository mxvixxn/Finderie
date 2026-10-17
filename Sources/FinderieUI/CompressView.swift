import SwiftUI
import ZipCore

// MARK: - 상태

/// 압축 전에 옵션을 확인하는 카드의 상태. [압축]을 누르면 작업이 된다.
@MainActor
final class CompressDraft: ObservableObject {
    let urls: [URL]
    @Published var output: URL
    @Published var counts: FileStats.Counts?

    init(urls: [URL]) {
        self.urls = urls
        self.output = ZipWriter.suggestedOutputURL(for: urls)
    }

    func measure(excludeMacFiles: Bool) {
        counts = nil
        let urls = urls
        Task.detached(priority: .userInitiated) {
            let c = FileStats.measure(urls, excludeMacFiles: excludeMacFiles)
            await MainActor.run { self.counts = c }
        }
    }

    var summary: String {
        guard let c = counts else { return "크기를 세는 중…" }
        var parts: [String] = []
        if c.folders > 0 { parts.append("폴더 \(c.folders)개") }
        parts.append("파일 \(c.files)개")
        parts.append(Fmt.bytes(c.bytes))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 화면

struct CompressConfirmView: View {
    @ObservedObject var draft: CompressDraft
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    init(draft: CompressDraft, model: AppModel) {
        self.draft = draft
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZipperGlyph(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.output.lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(draft.summary).font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                row("한글 이름") {
                    Picker("한글 이름", selection: $settings.nameEncoding) {
                        ForEach(NameEncoding.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    .help(settings.nameEncoding.detail)
                }
                Divider().padding(.leading, 14)
                row("속도") {
                    Picker("속도", selection: $settings.level) {
                        ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .help("빠르게는 크기가 조금 크고, 최대 압축은 조금 느려요")
                }
                Divider().padding(.leading, 14)
                row("Mac 숨김 파일 빼기") {
                    Toggle("Mac 숨김 파일 빼기", isOn: $settings.excludeMacFiles)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(".DS_Store, ._파일, __MACOSX처럼 Windows에서 쓸모없는 파일을 빼요")
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .card()

            HStack(spacing: 8) {
                Text("저장 위치").font(.callout).foregroundStyle(.secondary)
                Button(draft.output.deletingLastPathComponent().lastPathComponent) {
                    if let picked = Panels.pickSaveURL(suggested: draft.output) { draft.output = picked }
                }
                .buttonStyle(.link)
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
                .help(draft.output.path)
                Spacer()
                Button("취소") { model.compressDraft = nil }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                    .controlSize(.large)
                Button("압축") { model.compressFromDraft(draft) }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .tint(Theme.accent)
                    .controlSize(.large)
            }
        }
        .onChange(of: settings.excludeMacFiles) { _, on in draft.measure(excludeMacFiles: on) }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            control().fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}
