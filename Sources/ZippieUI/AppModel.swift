import AppKit
import Combine
import SwiftUI
import ZipCore

// MARK: - 설정

/// 압축을 풀 기본 위치
public enum ExtractDestination: String, CaseIterable, Identifiable, Sendable {
    case besideZip, desktop, downloads

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .besideZip: return "ZIP과 같은 폴더"
        case .desktop: return "바탕화면"
        case .downloads: return "다운로드"
        }
    }

    func directory(for zip: URL) -> URL? {
        let fm = FileManager.default
        switch self {
        case .besideZip: return nil
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
    }
}

/// 앱 설정. 값은 UserDefaults에 저장돼서 다음에 켜도 그대로다.
public final class AppSettings: ObservableObject {
    @AppStorage("nameEncoding") public var nameEncoding: NameEncoding = .windowsUTF8
    @AppStorage("level") public var level: CompressionLevel = .normal
    @AppStorage("excludeMacFiles") public var excludeMacFiles = true
    @AppStorage("storeCompressedFiles") public var storeCompressedFiles = true
    @AppStorage("background") public var background = false
    @AppStorage("skipPreview") public var skipPreview = false
    @AppStorage("extractDestination") public var extractDestination: ExtractDestination = .besideZip

    public init() {}

    func zipOptions(decoding: NameDecoding = .auto) -> ZipOptions {
        ZipOptions(nameEncoding: nameEncoding, excludeMacFiles: excludeMacFiles, level: level,
                   storeCompressedFiles: storeCompressedFiles, background: background, nameDecoding: decoding)
    }
}

// MARK: - 작업

/// 압축 또는 풀기 작업 하나. 화면의 카드 하나와 짝을 이룬다.
@MainActor
public final class Job: ObservableObject, Identifiable {
    public enum Kind: Sendable { case compress, extract }
    public enum Phase: Sendable { case queued, running, done, failed }

    public struct Failure {
        let title: String
        let reason: String
        let hint: String
        let cleanupNote: String
        /// 다시 시도하면 될 수도 있는 오류인지 (암호, 위험한 경로 같은 건 다시 해도 똑같다)
        var retryable = true
    }

    public let id = UUID()
    let kind: Kind
    let inputs: [URL]
    let displayName: String
    /// 압축: 만들 ZIP 경로 / 풀기: 풀 폴더 (nil이면 ZIP 옆)
    let target: URL?
    let decoding: NameDecoding
    let cancelToken = CancelToken()

    @Published var phase: Phase = .queued
    @Published var fraction: Double = 0
    @Published var currentName = ""
    @Published var totalBytes: UInt64 = 0
    @Published var bytesPerSecond: Double = 0
    @Published var secondsLeft: Double?
    @Published var resultURL: URL?
    @Published var summary = ""
    @Published var failure: Failure?
    var startedAt: Date?

    init(kind: Kind, inputs: [URL], target: URL?, decoding: NameDecoding = .auto, displayName: String? = nil) {
        self.kind = kind
        self.inputs = inputs
        self.target = target
        self.decoding = decoding
        self.displayName = displayName ?? Job.name(for: kind, inputs: inputs, target: target)
    }

    private static func name(for kind: Kind, inputs: [URL], target: URL?) -> String {
        switch kind {
        case .extract: return inputs.first?.lastPathComponent ?? "ZIP"
        case .compress:
            if inputs.count == 1 { return inputs[0].lastPathComponent }
            return target?.deletingPathExtension().lastPathComponent ?? "파일 \(inputs.count)개"
        }
    }

    var isActive: Bool { phase == .queued || phase == .running }

    /// 진행률이 올 때마다 속도와 남은 시간을 다시 계산한다.
    func update(fraction f: Double, name: String) {
        guard phase == .running else { return }
        fraction = max(fraction, min(f, 1))
        if !name.isEmpty && name != "준비 중" { currentName = name }
        guard let startedAt, totalBytes > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.25 else { return }
        let done = fraction * Double(totalBytes)
        bytesPerSecond = done / elapsed
        secondsLeft = bytesPerSecond > 0 ? (Double(totalBytes) - done) / bytesPerSecond : nil
    }
}

/// 최근 기록 한 줄. 앱을 다시 켜도 남도록 저장한다.
struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let name: String
    let isCompress: Bool
    let detail: String
    let path: String
    let date: Date
}

/// 끌고 들어오는 중인 파일에 대한 미리 계산
struct DragInfo {
    let isExtract: Bool
    let summary: String
}

// MARK: - 앱 상태

@MainActor
public final class AppModel: ObservableObject {
    public let settings: AppSettings
    @Published public internal(set) var jobs: [Job] = []
    @Published var history: [HistoryItem] = []
    @Published var preview: PreviewModel?
    @Published var dragInfo: DragInfo?
    @Published var isDropTargeted = false

    private var running: Job?
    private var forwarders: [AnyCancellable] = []
    private let historyKey = "history.v1"

    public init(settings: AppSettings = AppSettings(), loadsHistory: Bool = true) {
        self.settings = settings
        if loadsHistory { loadHistory() }
        // 설정이 바뀌면 화면도 다시 그린다
        forwarders.append(settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    // MARK: 받아들이기

    /// 놓거나 고르거나 Dock으로 들어온 파일. ZIP만 있으면 풀고, 아니면 압축한다.
    /// chooseLocation이 true면(⌥ 누른 채 놓기) 저장 위치를 먼저 묻는다.
    public func accept(_ urls: [URL], chooseLocation: Bool = false) {
        guard !urls.isEmpty else { return }
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if zips.count == urls.count {
            if zips.count == 1 && !settings.skipPreview && !chooseLocation {
                showPreview(zips[0])
                return
            }
            var dir: URL?
            if chooseLocation {
                guard let picked = Panels.pickFolder(prompt: "여기에 풀기") else { return }
                dir = picked
            }
            for zip in zips {
                enqueue(Job(kind: .extract, inputs: [zip],
                            target: dir ?? settings.extractDestination.directory(for: zip)))
            }
        } else {
            var output = ZipWriter.suggestedOutputURL(for: urls)
            if chooseLocation {
                guard let picked = Panels.pickSaveURL(suggested: output) else { return }
                output = picked
            }
            enqueue(Job(kind: .compress, inputs: urls, target: output))
        }
    }

    /// 파일 선택 창으로 고르기
    public func chooseFiles() {
        let urls = Panels.pickItems()
        accept(urls)
    }

    func showPreview(_ zip: URL) {
        let model = PreviewModel(zip: zip, destination: settings.extractDestination)
        preview = model
        model.load()
    }

    /// 미리보기에서 [풀기]
    func extractFromPreview(_ p: PreviewModel) {
        var dir: URL?
        switch p.destinationChoice {
        case .preset(let d): dir = d.directory(for: p.zip)
        case .custom(let url): dir = url
        }
        enqueue(Job(kind: .extract, inputs: [p.zip], target: dir, decoding: p.decoding))
        preview = nil
    }

    // MARK: 대기열

    func enqueue(_ job: Job) {
        jobs.append(job)
        runNext()
    }

    private func runNext() {
        guard running == nil, let next = jobs.first(where: { $0.phase == .queued }) else { return }
        running = next
        start(next)
    }

    private func start(_ job: Job) {
        job.phase = .running
        job.startedAt = Date()
        let options = settings.zipOptions(decoding: job.decoding)
        let kind = job.kind
        let inputs = job.inputs
        let target = job.target
        let token = job.cancelToken
        let priority: TaskPriority = settings.background ? .utility : .userInitiated

        Task.detached(priority: priority) { [weak self] in
            let total: UInt64
            switch kind {
            case .compress: total = FileStats.measure(inputs, excludeMacFiles: options.excludeMacFiles).bytes
            case .extract: total = ((try? ZipReader.entries(of: inputs[0])) ?? []).reduce(0) { $0 + $1.size }
            }
            await MainActor.run {
                job.totalBytes = total
                job.startedAt = Date()
            }
            let progress: ProgressHandler = { f, name in
                Task { @MainActor in job.update(fraction: f, name: name) }
            }
            let began = Date()
            do {
                switch kind {
                case .compress:
                    let out = target ?? ZipWriter.suggestedOutputURL(for: inputs)
                    try ZipWriter.compress(inputs, to: out, options: options, progress: progress, cancel: token)
                    let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
                    let took = Date().timeIntervalSince(began)
                    await MainActor.run {
                        job.resultURL = out
                        job.summary = "\(Fmt.bytes(total)) → \(Fmt.bytes(size)) · \(Fmt.seconds(took)) · \(options.nameEncoding.resultTitle)"
                        job.phase = .done
                        job.fraction = 1
                    }
                    await self?.finished(job, detail: "압축 · \(Fmt.bytes(size))")
                case .extract:
                    let r = try ZipReader.extract(inputs[0], to: target, options: options, progress: progress, cancel: token)
                    let took = Date().timeIntervalSince(began)
                    let names = AppModel.encodingNote(r.encoding)
                    await MainActor.run {
                        job.resultURL = r.destination
                        job.summary = "\(r.fileCount)개 파일 · \(Fmt.seconds(took))" + (names.isEmpty ? "" : " · \(names)")
                        job.phase = .done
                        job.fraction = 1
                    }
                    await self?.finished(job, detail: "풀기 · \(r.fileCount)개 파일" + (names.isEmpty ? "" : " · \(names)"))
                }
            } catch {
                await self?.failed(job, error: error)
            }
        }
    }

    private func failed(_ job: Job, error: Error) {
        if case ZipError.cancelled = error {
            jobs.removeAll { $0.id == job.id }
        } else {
            job.failure = AppModel.failure(for: error, job: job)
            job.phase = .failed
        }
        finished(job, detail: nil)
    }

    private func finished(_ job: Job, detail: String?) {
        if running?.id == job.id { running = nil }
        if let detail, let url = job.resultURL {
            addHistory(HistoryItem(id: job.id, name: url.lastPathComponent, isCompress: job.kind == .compress,
                                   detail: detail, path: url.path, date: Date()))
        }
        runNext()
    }

    // MARK: 카드 조작

    func cancel(_ job: Job) {
        if job.phase == .queued {
            jobs.removeAll { $0.id == job.id }
        } else {
            job.cancelToken.cancel()
        }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job) }
    }

    func dismiss(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func retry(_ job: Job) {
        dismiss(job)
        enqueue(Job(kind: job.kind, inputs: job.inputs, target: job.target, decoding: job.decoding))
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: 끌고 들어오기

    func dragEntered(_ urls: [URL]) {
        let excludeJunk = settings.excludeMacFiles
        Task.detached(priority: .userInitiated) { [weak self] in
            let info = FileStats.describe(urls, excludeMacFiles: excludeJunk)
            await self?.showDragInfo(info)
        }
    }

    private func showDragInfo(_ info: DragInfo) {
        if isDropTargeted { dragInfo = info }
    }

    // MARK: 최근 기록

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        history = items
    }

    private func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    // MARK: 문구

    nonisolated static func encodingNote(_ e: ZipReader.DetectedEncoding) -> String {
        switch e {
        case .cp949: return "한글 이름 복원(CP949)"
        case .forcedCP949: return "이름: CP949로 읽음"
        case .forcedUTF8: return "이름: UTF-8로 읽음"
        case .unknown: return "이름 인코딩 알 수 없음"
        default: return ""
        }
    }

    /// 오류를 사람이 이해할 수 있는 원인과 해결 방법으로 바꾼다.
    static func failure(for error: Error, job: Job) -> Job.Failure {
        let name = job.displayName
        let title = job.kind == .extract ? "\(Fmt.quoted(name)) 풀 수 없어요" : "\(Fmt.quoted(name)) 압축할 수 없어요"
        let cleanup = job.kind == .extract ? "반쯤 풀린 파일은 남기지 않고 정리했어요." : "만들던 압축 파일은 남기지 않고 지웠어요."
        guard let zipError = error as? ZipError else {
            return Job.Failure(title: title, reason: error.localizedDescription,
                               hint: "잠시 후 다시 시도해 보세요.", cleanupNote: cleanup)
        }
        switch zipError {
        case .checksumMismatch(let entry):
            let file = (entry as NSString).lastPathComponent
            return Job.Failure(title: title, reason: "데이터가 손상됐어요. ‘\(file)’의 내용이 원래와 달라요(CRC 불일치).",
                               hint: "다운로드가 중간에 끊겼을 수 있어요. 파일을 다시 받은 뒤 풀어 보세요.", cleanupNote: cleanup)
        case .corrupt(let why) where why.hasPrefix("압축 데이터 오류: "):
            let file = (String(why.dropFirst("압축 데이터 오류: ".count)) as NSString).lastPathComponent
            return Job.Failure(title: title, reason: "데이터가 손상됐어요. ‘\(file)’의 압축 데이터가 깨져 있어요.",
                               hint: "다운로드가 중간에 끊겼을 수 있어요. 파일을 다시 받은 뒤 풀어 보세요.", cleanupNote: cleanup)
        case .corrupt(let why):
            return Job.Failure(title: title, reason: "ZIP 파일이 손상됐거나 지원하지 않는 형식이에요. (\(why))",
                               hint: "다운로드가 중간에 끊겼을 수 있어요. 파일을 다시 받은 뒤 풀어 보세요.", cleanupNote: cleanup)
        case .encrypted:
            return Job.Failure(title: title, reason: "암호가 걸린 ZIP이에요.",
                               hint: "암호 ZIP은 아직 지원하지 않아요. 반디집이나 Mac 기본 압축 풀기를 이용해 주세요.", cleanupNote: cleanup, retryable: false)
        case .unsupportedMethod(_, let method):
            return Job.Failure(title: title, reason: "Zippie가 아직 모르는 압축 방식(\(method))이에요.",
                               hint: "다른 압축 프로그램으로 풀어 보세요.", cleanupNote: cleanup, retryable: false)
        case .unsafePath(let path):
            return Job.Failure(title: title, reason: "압축 파일 밖으로 빠져나가는 위험한 경로가 있어요. (\(path))",
                               hint: "안전을 위해 풀지 않았어요. 믿을 수 있는 곳에서 받은 파일인지 확인해 보세요.", cleanupNote: cleanup, retryable: false)
        case .cannotRead:
            return Job.Failure(title: title, reason: "파일을 읽거나 쓸 수 없어요.",
                               hint: "파일 접근 권한이나 남은 저장 공간을 확인해 보세요.", cleanupNote: cleanup)
        case .nothingToCompress:
            return Job.Failure(title: title, reason: "압축할 파일이 없어요.",
                               hint: "Mac 숨김 파일만 들어 있는 폴더일 수 있어요.", cleanupNote: cleanup, retryable: false)
        case .tooLarge, .cancelled:
            return Job.Failure(title: title, reason: zipError.localizedDescription,
                               hint: "잠시 후 다시 시도해 보세요.", cleanupNote: cleanup)
        }
    }
}

// MARK: - 파일 크기 세기

enum FileStats {
    struct Counts {
        var files = 0
        var folders = 0
        var bytes: UInt64 = 0
    }

    /// 압축할 파일의 개수와 크기 (폴더 안까지). 아주 큰 폴더도 멈추지 않게 20만 개까지만 센다.
    static func measure(_ urls: [URL], excludeMacFiles: Bool) -> Counts {
        var c = Counts()
        let fm = FileManager.default
        var seen = 0
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                c.files += 1
                c.bytes += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                continue
            }
            c.folders += 1
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { continue }
            for case let item as URL in walker {
                seen += 1
                if seen > 200_000 { return c }
                if excludeMacFiles, ["DS_Store", ".DS_Store"].contains(item.lastPathComponent) || item.lastPathComponent.hasPrefix("._") { continue }
                let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true { continue }
                c.files += 1
                c.bytes += UInt64(v?.fileSize ?? 0)
            }
        }
        return c
    }

    static func describe(_ urls: [URL], excludeMacFiles: Bool) -> DragInfo {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if !urls.isEmpty && zips.count == urls.count {
            let bytes = zips.reduce(UInt64(0)) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return DragInfo(isExtract: true, summary: "ZIP \(zips.count)개 · \(Fmt.bytes(bytes))")
        }
        let c = measure(urls, excludeMacFiles: excludeMacFiles)
        var parts: [String] = []
        if c.folders > 0 { parts.append("폴더 \(c.folders)개") }
        parts.append("파일 \(c.files)개")
        parts.append(Fmt.bytes(c.bytes))
        return DragInfo(isExtract: false, summary: parts.joined(separator: " · "))
    }
}

// MARK: - 파일 선택 창

enum Panels {
    @MainActor static func pickItems() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "선택"
        panel.message = "ZIP을 고르면 풀고, 다른 파일이나 폴더를 고르면 압축해요"
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor static func pickFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func pickSaveURL(suggested: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.allowedContentTypes = [.zip]
        panel.prompt = "압축"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
