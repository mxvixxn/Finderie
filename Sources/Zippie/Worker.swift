import AppKit
import SwiftUI
import ZipCore

enum Mode: String, CaseIterable, Identifiable {
    case compress, extract
    var id: String { rawValue }
    var title: String { self == .compress ? "압축하기" : "압축 풀기" }
}

@MainActor
final class Worker: ObservableObject {
    enum Status {
        case idle
        case working(progress: Double, name: String)
        case done(message: String, url: URL)
        case failed(String)
    }

    @Published var mode: Mode = .compress
    @Published var status: Status = .idle

    @AppStorage("nameEncoding") var nameEncoding: NameEncoding = .windowsUTF8
    @AppStorage("excludeMacFiles") var excludeMacFiles = true
    @AppStorage("level") var level: CompressionLevel = .normal
    @AppStorage("storeCompressedFiles") var storeCompressedFiles = true
    @AppStorage("background") var background = false

    var isBusy: Bool { if case .working = status { return true } else { return false } }

    private var options: ZipOptions {
        ZipOptions(nameEncoding: nameEncoding, excludeMacFiles: excludeMacFiles,
                   level: level, storeCompressedFiles: storeCompressedFiles, background: background)
    }

    func handleOpened(_ urls: [URL]) {
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "zip" }) {
            mode = .extract
        } else {
            mode = .compress
        }
        run(urls)
    }

    func run(_ urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        status = .working(progress: 0, name: "")
        let mode = self.mode
        let options = self.options

        let started = Date()
        Task.detached(priority: options.background ? .utility : .userInitiated) {
            func took() -> String { String(format: "%.1f초", Date().timeIntervalSince(started)) }
            let report: ProgressHandler = { p, name in
                Task { @MainActor in
                    guard self.isBusy else { return }
                    self.status = .working(progress: p, name: name)
                }
            }
            do {
                switch mode {
                case .compress:
                    let out = ZipWriter.suggestedOutputURL(for: urls)
                    let stats = try ZipWriter.compress(urls, to: out, options: options, progress: report)
                    let note = stats.sequentialIO ? " · 외장 드라이브 모드" : ""
                    await self.finish(.done(message: "\(out.lastPathComponent) 만들기 완료 · \(took())\(note)", url: out))
                case .extract:
                    var last: (URL, String)?
                    for zip in urls where zip.pathExtension.lowercased() == "zip" {
                        let r = try ZipReader.extract(zip, options: options, progress: report)
                        let note = r.sequentialIO ? " · 외장 드라이브 모드" : ""
                        last = (r.destination, "\(r.fileCount)개 파일 풀기 완료 · \(took())\(note) · 이름: \(r.encoding.rawValue)")
                    }
                    if let (url, msg) = last {
                        await self.finish(.done(message: msg, url: url))
                    } else {
                        await self.finish(.failed("ZIP 파일을 넣어 주세요."))
                    }
                }
            } catch {
                await self.finish(.failed(error.localizedDescription))
            }
        }
    }

    private func finish(_ s: Status) { status = s }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if mode == .compress {
            panel.canChooseDirectories = true
            panel.prompt = "압축하기"
        } else {
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.zip]
            panel.prompt = "풀기"
        }
        if panel.runModal() == .OK { run(panel.urls) }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
