import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZipCore

/// Finderie 메인 창의 내용. 상태(기다림 · 미리보기 · 작업 중 · 완료 · 오류)에 따라 구성이 바뀐다.
public struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    public init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.tab == .prep {
                PrepScreen(model: model)
            } else if settings.tab == .shrink {
                ShrinkScreen(model: model)
            } else if let preview = model.preview {
                PreviewView(preview: preview, model: model)
            } else if let draft = model.compressDraft {
                CompressConfirmView(draft: draft, model: model)
            } else if model.jobs.isEmpty {
                DropWell(model: model, size: .large)
            } else {
                let active = model.jobs.filter(\.isActive)
                let finished = model.jobs.filter { !$0.isActive }.reversed().map { $0 }
                if !active.isEmpty {
                    DropWell(model: model, size: .compact)
                    ActiveSection(model: model, jobs: active)
                    if !finished.isEmpty { FinishedSection(model: model, jobs: finished) }
                } else {
                    FinishedSection(model: model, jobs: finished)
                    DropWell(model: model, size: .medium)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 460)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(model: model))
        .animation(.snappy(duration: 0.25), value: model.jobs.map(\.id))
        .animation(.snappy(duration: 0.2), value: settings.tab)
        .animation(.snappy(duration: 0.2), value: model.isDropTargeted)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabSwitcher(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                HistoryButton(model: model)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("설정")
                .accessibilityLabel("설정")
            }
        }
    }
}

// MARK: - 놓는 칸

struct DropWell: View {
    enum Size { case large, medium, compact }

    @ObservedObject var model: AppModel
    let size: Size

    private var targeted: Bool { model.isDropTargeted }
    private var actionTitle: String {
        guard let info = model.dragInfo else { return "놓으면 처리해요" }
        return info.isExtract ? "놓으면 풀어요" : "놓으면 압축해요"
    }

    var body: some View {
        Group {
            switch size {
            case .large: large
            case .medium: medium
            case .compact: compact
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size == .large ? 232 : 64)
        .glassSurface(in: RoundedRectangle(cornerRadius: size == .compact ? 14 : 16, style: .continuous),
                    tint: targeted ? Theme.accent.opacity(0.35) : nil, interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("파일을 놓는 곳")
    }

    private var large: some View {
        VStack(spacing: 10) {
            if targeted {
                Image(systemName: model.dragInfo?.isExtract == true ? "arrow.up.doc" : "arrow.down.doc")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 64)
                    .accessibilityHidden(true)
                Text(actionTitle).font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(model.dragInfo?.summary ?? " ").font(.body).foregroundStyle(.secondary)
            } else {
                ZipperGlyph(size: 64)
                Text("파일이나 폴더를 놓으세요").font(.title3.weight(.semibold))
                    .help("ZIP은 풀고, 나머지는 압축해요")
                Button("파일 선택…") { model.chooseFiles() }
                    .buttonStyle(.link)
            }
        }
    }

    private var medium: some View {
        VStack(spacing: 6) {
            if targeted {
                Text(actionTitle).font(.title3.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(model.dragInfo?.summary ?? " ").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("파일이나 폴더를 놓으세요").font(.headline)
                    Button("파일 선택…") { model.chooseFiles() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 8) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "plus")
                .font(.headline)
                .foregroundStyle(targeted ? Theme.accent : .secondary)
                .accessibilityHidden(true)
            Text(targeted ? "\(actionTitle) · 이어서 처리해요" : "더 놓으면 이어서 처리해요")
                .font(.body.weight(targeted ? .semibold : .regular))
                .foregroundStyle(targeted ? Theme.accent : .secondary)
        }
    }

}

/// 창 전체가 파일을 받는다. 들어오는 순간 무엇인지 미리 계산해서 놓는 칸에 보여 준다.
struct FileDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        let free: Bool
        switch model.settings.tab {
        case .prep: free = model.prep?.isBusy != true
        case .shrink: free = model.shrink?.isBusy != true
        case .zip: free = model.preview == nil && model.compressDraft == nil
        }
        return free && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        model.isDropTargeted = true
        model.dragInfo = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            if model.isDropTargeted { model.dragEntered(urls) }
        }
    }

    func dropExited(info: DropInfo) {
        model.isDropTargeted = false
        model.dragInfo = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let chooseLocation = NSEvent.modifierFlags.contains(.option)
        model.isDropTargeted = false
        model.dragInfo = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            model.accept(urls, chooseLocation: chooseLocation)
        }
        return true
    }

    /// 끌어온 항목들에서 파일 주소를 꺼낸다 (순서 유지).
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, provider) in providers.enumerated() {
                group.addTask {
                    await withCheckedContinuation { cont in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let data = item as? Data {
                                cont.resume(returning: (i, URL(dataRepresentation: data, relativeTo: nil)))
                            } else {
                                cont.resume(returning: (i, item as? URL))
                            }
                        }
                    }
                }
            }
            var found: [(Int, URL)] = []
            for await (i, url) in group { if let url { found.append((i, url)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - 탭

/// 제목 막대 가운데의 화면 고르기. 일하는 중에는 바꿀 수 없다.
public struct TabSwitcher: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    public init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    public var body: some View {
        Picker("화면", selection: $settings.tab) {
            ForEach(AppTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(model.isToolBusy)
    }
}

// MARK: - 최근 기록

struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: AppModel

    private var exists: Bool { FileManager.default.fileExists(atPath: item.path) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isCompress ? "doc.zipper" : "folder")
                .font(.body.weight(.medium))
                .foregroundStyle(item.isCompress ? Theme.accent : .secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(item.detail) · \(Fmt.relative(item.date))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(systemName: "magnifyingglass", label: "Finder에서 보기") {
                model.reveal(URL(fileURLWithPath: item.path))
            }
            .disabled(!exists)
            .opacity(exists ? 1 : 0.35)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 52)
    }
}

/// 도구 막대의 시계 버튼: 최근 기록 전체를 보여 준다.
struct HistoryButton: View {
    @ObservedObject var model: AppModel
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "clock")
        }
        .help("최근 작업")
        .accessibilityLabel("최근 작업")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("최근 작업").font(.headline)
                    Spacer()
                    if !model.history.isEmpty {
                        Button("기록 지우기") { model.clearHistory() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                if model.history.isEmpty {
                    Text("아직 기록이 없어요").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.history) { item in
                                HistoryRow(item: item, model: model)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.history.count) * 52, 360))
                }
            }
            .padding(14)
            .frame(width: 360)
        }
    }
}
