import AppKit
import SwiftUI
import ZipCore

// MARK: - 미리보기 상태

/// ZIP 안의 한 줄 (폴더 구조를 펼친 순서)
struct PreviewRow: Identifiable {
    enum Kind { case folder, image, file }
    let id: Int
    let name: String
    let depth: Int
    let kind: Kind
    let size: UInt64
    let childCount: Int
}

@MainActor
final class PreviewModel: ObservableObject {
    enum DestinationChoice: Equatable {
        case preset(ExtractDestination)
        case custom(URL)
    }

    let zip: URL
    @Published var decoding: NameDecoding = .auto
    @Published var rows: [PreviewRow] = []
    @Published var hiddenCount = 0
    @Published var detected: ZipReader.DetectedEncoding = .ascii
    @Published var fileCount = 0
    @Published var totalSize: UInt64 = 0
    @Published var loading = true
    @Published var errorText: String?
    @Published var destinationChoice: DestinationChoice
    let archiveSize: UInt64

    init(zip: URL, destination: ExtractDestination) {
        self.zip = zip
        destinationChoice = .preset(destination)
        archiveSize = UInt64((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func load() {
        loading = true
        let zip = zip
        let decoding = decoding
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let entries = try ZipReader.entries(of: zip, decoding: decoding)
                let tree = PreviewTree.build(entries)
                await self?.show(tree)
            } catch {
                await self?.show(error: error.localizedDescription)
            }
        }
    }

    private func show(_ tree: PreviewTree.Result) {
        rows = tree.rows
        hiddenCount = tree.hidden
        detected = tree.encoding
        fileCount = tree.files
        totalSize = tree.bytes
        errorText = nil
        loading = false
    }

    private func show(error: String) {
        errorText = error
        loading = false
    }

    func setDecoding(_ d: NameDecoding) {
        guard d != decoding else { return }
        decoding = d
        load()
    }

    var destinationTitle: String {
        switch destinationChoice {
        case .preset(let d): return d.title
        case .custom(let url): return url.lastPathComponent
        }
    }
}

/// ZIP 항목 목록을 폴더 구조로 정리한다.
enum PreviewTree {
    struct Result {
        var rows: [PreviewRow] = []
        var hidden = 0
        var encoding: ZipReader.DetectedEncoding = .ascii
        var files = 0
        var bytes: UInt64 = 0
    }

    private final class Node {
        let name: String
        var isFolder: Bool
        var size: UInt64 = 0
        var children: [String: Node] = [:]
        init(name: String, isFolder: Bool) { self.name = name; self.isFolder = isFolder }
        var fileCount: Int { isFolder ? children.values.reduce(0) { $0 + $1.fileCount } : 1 }
    }

    static let maxRows = 400
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]

    static func build(_ entries: [ZipReader.Entry]) -> Result {
        let root = Node(name: "", isFolder: true)
        var counts: [ZipReader.DetectedEncoding: Int] = [:]
        var result = Result()
        for e in entries {
            let parts = e.name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            if parts.isEmpty || parts.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" || $0.hasPrefix("._") }) { continue }
            counts[e.encoding, default: 0] += 1
            var node = root
            for (i, part) in parts.enumerated() {
                let last = i == parts.count - 1
                let folder = !last || e.isDirectory
                if let next = node.children[part] {
                    node = next
                } else {
                    let next = Node(name: part, isFolder: folder)
                    node.children[part] = next
                    node = next
                }
            }
            if !e.isDirectory {
                node.size = e.size
                result.files += 1
                result.bytes += e.size
            }
        }
        result.encoding = counts.filter { $0.key != .ascii }.max { $0.value < $1.value }?.key ?? .ascii

        var id = 0
        func walk(_ node: Node, depth: Int) {
            let sorted = node.children.values.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for child in sorted {
                if result.rows.count >= maxRows { result.hidden += child.isFolder ? child.fileCount : 1; continue }
                let ext = (child.name as NSString).pathExtension.lowercased()
                let kind: PreviewRow.Kind = child.isFolder ? .folder : (imageExtensions.contains(ext) ? .image : .file)
                result.rows.append(PreviewRow(id: id, name: child.name, depth: depth, kind: kind,
                                              size: child.size, childCount: child.isFolder ? child.fileCount : 0))
                id += 1
                if child.isFolder { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return result
    }
}

// MARK: - 미리보기 화면

struct PreviewView: View {
    @ObservedObject var preview: PreviewModel
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if preview.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("목록을 읽고 있어요…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error = preview.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                banner
                fileList
            }
            Toggle(isOn: Binding(get: { model.settings.skipPreview }, set: { model.settings.skipPreview = $0 })) {
                Text("다음부터는 미리보기 없이 바로 풀기").font(.system(size: 12.5))
            }
            .toggleStyle(.checkbox)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(Theme.sky.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.zip.lastPathComponent)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1).truncationMode(.middle)
                Text(preview.loading ? Fmt.bytes(preview.archiveSize)
                     : "\(preview.fileCount)개 파일 · \(Fmt.bytes(preview.archiveSize)) · 풀면 \(Fmt.bytes(preview.totalSize))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bannerText: (title: String, detail: String, warn: Bool) {
        switch preview.detected {
        case .cp949: return ("Windows(CP949)에서 만든 압축 파일이에요", "한글 이름을 자동으로 복원했어요. 깨져 보이면 인코딩을 바꿔 보세요.", false)
        case .utf8Flag, .unicodeExtra: return ("한글 이름이 UTF-8로 저장된 파일이에요", "Windows와 Mac 어디서든 이름이 그대로 보여요.", false)
        case .utf8NoFlag: return ("Mac에서 만든 압축 파일이에요", "한글 이름을 그대로 읽었어요.", false)
        case .ascii: return ("영문 이름만 들어 있어요", "인코딩 걱정 없이 풀 수 있어요.", false)
        case .forcedUTF8, .forcedCP949: return ("인코딩을 직접 지정했어요", "이름이 제대로 보이는지 아래 목록에서 확인해 보세요.", false)
        case .unknown: return ("이름 인코딩을 알 수 없어요", "이름이 깨져 보이면 인코딩을 바꿔 보세요.", true)
        }
    }

    private var banner: some View {
        let t = bannerText
        let tint = t.warn ? Theme.warning : Theme.primary
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: t.warn ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 13, weight: .semibold))
                Text(t.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Menu {
                Picker("이름 인코딩", selection: Binding(get: { preview.decoding }, set: { preview.setDecoding($0) })) {
                    ForEach(NameDecoding.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Text(preview.decoding == .auto ? "자동" : preview.decoding.title)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("파일 이름을 읽을 인코딩")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(preview.rows) { row in
                    PreviewRowView(row: row)
                }
                if preview.hiddenCount > 0 {
                    Text("외 \(preview.hiddenCount)개")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                        .frame(height: 28)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: min(CGFloat(preview.rows.count + (preview.hiddenCount > 0 ? 1 : 0)) * 30 + 8, 270))
        .card(radius: 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("풀 위치").font(.system(size: 12.5)).foregroundStyle(.secondary)
            Menu {
                ForEach(ExtractDestination.allCases) { d in
                    Button(d.title) { preview.destinationChoice = .preset(d) }
                }
                Divider()
                Button("다른 위치…") {
                    if let url = Panels.pickFolder(prompt: "여기에 풀기") { preview.destinationChoice = .custom(url) }
                }
            } label: {
                Text(preview.destinationTitle).font(.system(size: 12.5))
            }
            .fixedSize()
            Spacer()
            Button("취소") { model.preview = nil }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("풀기") { model.extractFromPreview(preview) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .controlSize(.large)
                .disabled(preview.loading || preview.errorText != nil)
        }
    }
}

struct PreviewRowView: View {
    let row: PreviewRow

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(row.name)
                .font(.system(size: 13, weight: row.kind == .folder ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(row.kind == .folder ? "\(row.childCount)개" : Fmt.bytes(row.size))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 12 + CGFloat(row.depth) * 18)
        .padding(.trailing, 12)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .folder:
            Image(systemName: "folder.fill").foregroundStyle(Theme.skyLight)
        case .image:
            Image(systemName: "photo").foregroundStyle(.secondary)
        case .file:
            Image(systemName: "doc").foregroundStyle(.secondary)
        }
    }
}
