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
            Picker("화면", selection: $settings.tab) {
                ForEach(AppTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.prep?.isBusy == true)

            if settings.tab == .prep {
                PrepScreen(model: model)
            } else if let preview = model.preview {
                PreviewView(preview: preview, model: model)
            } else if model.jobs.isEmpty {
                DropWell(model: model, size: .large)
                OptionChips(settings: model.settings)
                RecentSection(model: model, limit: 3)
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
                OptionChips(settings: model.settings)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 440)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(model: model))
        .animation(.snappy(duration: 0.25), value: model.jobs.map(\.id))
        .animation(.snappy(duration: 0.2), value: settings.tab)
        .animation(.snappy(duration: 0.2), value: model.isDropTargeted)
        .toolbar {
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
        .frame(height: size == .large ? 232 : size == .medium ? 120 : 64)
        .background(targeted ? Theme.sky.opacity(0.13) : Theme.sky.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: size == .compact ? 14 : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size == .compact ? 14 : 16, style: .continuous)
                .strokeBorder(targeted ? Theme.sky : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [6, 4]))
        )
        .shadow(color: targeted ? Theme.sky.opacity(0.25) : .clear, radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("파일을 놓는 곳")
    }

    private var large: some View {
        VStack(spacing: 10) {
            if targeted {
                Image(systemName: model.dragInfo?.isExtract == true ? "arrow.up.doc" : "arrow.down.doc")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Theme.sky, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Theme.sky.opacity(0.35), radius: 10, y: 6)
                    .accessibilityHidden(true)
                Text(actionTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.primary)
                Text(model.dragInfo?.summary ?? " ").font(.system(size: 13)).foregroundStyle(.secondary)
                optionHint
            } else {
                ZipperGlyph(size: 64)
                Text("파일이나 폴더를 놓으세요").font(.system(size: 15, weight: .semibold))
                Text("ZIP은 풀고, 나머지는 압축해요").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("파일 선택…") { model.chooseFiles() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
    }

    private var medium: some View {
        VStack(spacing: 6) {
            if targeted {
                Text(actionTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.primary)
                Text(model.dragInfo?.summary ?? " ").font(.system(size: 12.5)).foregroundStyle(.secondary)
                optionHint
            } else {
                Text("파일이나 폴더를 놓으세요").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 4) {
                    Text("ZIP은 풀고, 나머지는 압축해요").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Button("파일 선택…") { model.chooseFiles() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12.5))
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 8) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(targeted ? Theme.primary : .secondary)
                .accessibilityHidden(true)
            Text(targeted ? "\(actionTitle) · 이어서 처리해요" : "더 놓으면 이어서 처리해요")
                .font(.system(size: 13, weight: targeted ? .semibold : .regular))
                .foregroundStyle(targeted ? Theme.primary : .secondary)
        }
    }

    private var optionHint: some View {
        HStack(spacing: 6) {
            Text("⌥")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.primary.opacity(0.35), lineWidth: 0.5))
            Text("누른 채 놓으면 저장 위치를 고를 수 있어요")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// 창 전체가 파일을 받는다. 들어오는 순간 무엇인지 미리 계산해서 놓는 칸에 보여 준다.
struct FileDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        let free = model.settings.tab == .prep ? model.prep?.isBusy != true : model.preview == nil
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

// MARK: - 옵션 칩

struct OptionChips: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("한글 파일 이름", selection: $settings.nameEncoding) {
                    ForEach(NameEncoding.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                ChipLabel(caption: "한글", value: settings.nameEncoding.shortTitle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(settings.nameEncoding.detail)

            Menu {
                Picker("압축 속도", selection: $settings.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                ChipLabel(caption: "속도", value: settings.level.title)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("빠르게는 크기가 조금 크고, 최대 압축은 조금 느려요")

            Button {
                settings.excludeMacFiles.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: settings.excludeMacFiles ? "checkmark" : "eye")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(settings.excludeMacFiles ? "Mac 숨김 파일 제외" : "Mac 숨김 파일 포함")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(settings.excludeMacFiles ? Theme.primary : .primary)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(settings.excludeMacFiles ? Theme.sky.opacity(0.14) : Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(settings.excludeMacFiles ? Theme.sky.opacity(0.45) : Theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(".DS_Store, ._파일, __MACOSX처럼 Windows에서 쓸모없는 파일을 빼요")
            .accessibilityValue(settings.excludeMacFiles ? "켬" : "끔")
        }
    }
}

struct ChipLabel: View {
    let caption: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(caption).foregroundStyle(.secondary)
            Text(value)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

// MARK: - 최근 기록

struct RecentSection: View {
    @ObservedObject var model: AppModel
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("최근").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)
            if model.history.isEmpty {
                Text("압축하거나 푼 파일이 여기에 나와요")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .card(radius: 12)
            } else {
                VStack(spacing: 0) {
                    let items = Array(model.history.prefix(limit))
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        HistoryRow(item: item, model: model)
                        if i < items.count - 1 { Divider().padding(.leading, 54) }
                    }
                }
                .card(radius: 12)
            }
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: AppModel

    private var exists: Bool { FileManager.default.fileExists(atPath: item.path) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isCompress ? "doc.zipper" : "folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.isCompress ? Theme.primary : .secondary)
                .frame(width: 30, height: 30)
                .background(item.isCompress ? Theme.sky.opacity(0.14) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(item.detail) · \(Fmt.relative(item.date))").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
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
                    Text("최근 작업").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !model.history.isEmpty {
                        Button("기록 지우기") { model.clearHistory() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
                if model.history.isEmpty {
                    Text("아직 기록이 없어요").font(.system(size: 12.5)).foregroundStyle(.secondary)
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
