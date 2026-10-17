import AVFoundation
import ConvertCore
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import ZipCore

/// 용량 줄이기: 사진, 영상, PDF, 소리를 보내기 좋은 크기로 줄인다.
///
/// 1. scan으로 줄일 수 있는 파일을 찾고 단계별로 결과 크기를 예상한다.
/// 2. apply로 복사본을 만들거나 원본을 바꾼다. 별로 안 작아지는 파일은 그대로 둔다.
///
/// 새 파일은 영문 임시 이름으로 만든 뒤 POSIX로 옮긴다. ImageIO, AVFoundation, PDFKit은
/// 경로를 자모로 풀어(NFD) 쓰기 때문에 한글 이름을 그대로 넘기면 Windows에서 깨진다.
public enum Shrink {
    public enum Level: Int, CaseIterable, Identifiable, Sendable {
        case light, medium, strong
        public var id: Int { rawValue }

        /// 사진 긴 변
        var photoEdge: Int { [3840, 2560, 1600][rawValue] }
        /// JPG/HEIC 화질
        var photoQuality: Double { [0.85, 0.75, 0.6][rawValue] }
        /// 같은 해상도일 때 대략 남는 비율 (보통 사진기 화질 0.9~0.95 기준)
        var qualityFactor: Double { [0.75, 0.55, 0.4][rawValue] }
        /// 영상 짧은 변 상한 (화면 녹화는 더 크게 둔다)
        public var videoLabel: String { ["1080p", "720p", "540p"][rawValue] }
        /// 소리 AAC 비트레이트 (스테레오 기준)
        var audioBitrate: Int { [256_000, 192_000, 128_000][rawValue] }
        public var audioLabel: String { "\(audioBitrate / 1000)kbps" }
        var pdfFactor: Double { [0.6, 0.35, 0.2][rawValue] }
        public var photoLabel: String { "긴 변 \(photoEdge)px" }
    }

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case photo, video, pdf, audio
        public var id: String { rawValue }

        static func of(_ name: String) -> Kind? {
            switch (name as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "bmp", "webp", "avif": return .photo
            case "mov", "mp4", "m4v": return .video
            case "pdf": return .pdf
            case "wav", "aif", "aiff", "aifc", "caf", "flac", "m4a": return .audio
            default: return nil
            }
        }
    }

    public struct Item: Identifiable, Sendable {
        public let id = UUID()
        public let kind: Kind
        /// 고른 항목 기준 상대 경로 (화면용)
        public let path: String
        public let size: UInt64
        /// 단계별 예상 크기
        public let estimates: [UInt64]
        /// "4032×3024", "3분 12초 · 4K" 같은 설명
        public let detail: String
        /// 영상을 HEVC로 만들 때의 단계별 예상 크기
        var hevcEstimates: [UInt64]? = nil

        public func estimate(_ level: Level, hevc: Bool = false) -> UInt64 {
            (hevc ? hevcEstimates ?? estimates : estimates)[level.rawValue]
        }
    }

    public struct Outcome: Sendable {
        public var items: [URL] = []
        public var folder: URL?
        public var before: UInt64 = 0
        public var after: UInt64 = 0
        public var shrunk = 0
        /// 줄여도 별로 안 작아져서 그대로 둔 파일
        public var kept = 0
        public var failed: [String] = []
        public var trashed: [URL] = []
    }

    public final class Report: @unchecked Sendable {
        public let roots: [URL]
        public let items: [Item]
        public let fileCount: Int
        public let totalBytes: UInt64
        let tree: [Node]

        init(roots: [URL], items: [Item], fileCount: Int, totalBytes: UInt64, tree: [Node]) {
            self.roots = roots
            self.items = items
            self.fileCount = fileCount
            self.totalBytes = totalBytes
            self.tree = tree
        }

        public func items(of kind: Kind) -> [Item] { items.filter { $0.kind == kind } }
        public var kinds: [Kind] { Kind.allCases.filter { k in items.contains { $0.kind == k } } }

        /// 고른 종류와 단계로 줄였을 때 전체 예상 크기
        public func estimatedTotal(kinds: Set<Kind>, level: Level, hevc: Bool = false) -> UInt64 {
            let chosen = items.filter { kinds.contains($0.kind) }
            return totalBytes - chosen.reduce(0) { $0 + $1.size } + chosen.reduce(0) { $0 + $1.estimate(level, hevc: hevc) }
        }
    }

    final class Node {
        let path: String
        let name: String
        let walksInside: Bool
        let size: UInt64
        var kind: Kind?
        var item: Item?
        var children: [Node] = []

        init(path: String, name: String, walksInside: Bool, size: UInt64) {
            self.path = path
            self.name = name
            self.walksInside = walksInside
            self.size = size
        }
    }

    // MARK: - 검사

    public static func scan(_ urls: [URL], cancel: CancelToken? = nil) throws -> Report {
        var items: [Item] = []
        var files = 0
        var bytes: UInt64 = 0

        func load(_ path: String, name: String, shown: String) throws -> Node {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            var st = stat()
            guard lstat(path, &st) == 0 else { throw SendPrep.Failure(message: "파일을 읽지 못했어요: \(display(name))") }
            let kind = st.st_mode & S_IFMT
            let isPackage = kind == S_IFDIR
                && ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false)
            let node = Node(path: path, name: name, walksInside: kind == S_IFDIR && !isPackage,
                            size: kind == S_IFREG ? UInt64(st.st_size) : 0)
            if node.walksInside {
                node.children = try POSIX.list(path).sorted()
                    .filter { !$0.hasPrefix(".") }
                    .map { try load(path + "/" + $0, name: $0, shown: shown + "/" + display($0)) }
            } else {
                files += 1
                bytes += node.size
                if kind == S_IFREG, let k = Kind.of(name), let item = inspect(path, kind: k, size: node.size, shown: shown) {
                    node.kind = k
                    node.item = item
                    items.append(item)
                }
            }
            return node
        }

        let tree = try urls.map { url -> Node in
            let parent = url.deletingLastPathComponent().path
            let shown = url.lastPathComponent
            let stored = POSIX.list(parent).first { $0 == shown } ?? shown
            return try load(parent + "/" + stored, name: stored, shown: display(stored))
        }
        return Report(roots: urls, items: items, fileCount: files, totalBytes: bytes, tree: tree)
    }

    /// 파일을 열어 크기 예상에 필요한 정보(해상도, 길이)를 읽는다. 줄일 게 없으면 nil.
    static func inspect(_ path: String, kind: Kind, size: UInt64, shown: String) -> Item? {
        let levels = Level.allCases
        func clamp(_ v: Double) -> UInt64 { UInt64(max(0, min(Double(size), v))) }
        switch kind {
        case .photo:
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            let lossless = ["png", "tif", "tiff", "bmp"].contains(ext)
            let edge = Double(max(w, h))
            let est = levels.map { l -> UInt64 in
                let area = min(1, pow(Double(l.photoEdge) / edge, 2))
                switch ext {
                case "png": return clamp(Double(size) * area)
                case "tif", "tiff", "bmp": return clamp(Double(w * h) * area * 0.35 * l.qualityFactor)
                default: return clamp(Double(size) * area * l.qualityFactor)
                }
            }
            // 이미 충분히 작은 PNG는 줄일 수 없다
            if lossless && ext == "png" && edge <= Double(Level.light.photoEdge) && est.allSatisfy({ $0 >= size }) { return nil }
            return Item(kind: kind, path: shown, size: size, estimates: est, detail: "\(w)×\(h)")

        case .video:
            guard let info = videoInfo(path), info.duration > 0, info.size != .zero else { return nil }
            let screen = isScreenRecording((path as NSString).lastPathComponent)
            func est(_ hevc: Bool) -> [UInt64] {
                levels.map { clamp(VideoPlan(size: info.size, fps: info.fps, screen: screen, level: $0, hevc: hevc).estimate(duration: info.duration)) }
            }
            var label = Fmt2.duration(info.duration) + " · " + Fmt2.resolution(info.size)
            if info.fps > 30.5 { label += " · \(Int(info.fps.rounded()))fps" }
            if screen { label += " · 화면 녹화" }
            return Item(kind: kind, path: shown, size: size, estimates: est(false), detail: label, hevcEstimates: est(true))

        case .audio:
            // 무손실(PCM · FLAC · ALAC)만 줄인다. 이미 AAC·MP3인 m4a는 더 줄여도 음질만 나빠진다.
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let info = blocking({ () async throws -> (Double, FourCharCode, Int) in
                let duration = try await asset.load(.duration).seconds
                guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                      let format = try await track.load(.formatDescriptions).first else { return (duration, 0, 0) }
                let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame ?? 2
                return (duration, CMFormatDescriptionGetMediaSubType(format), Int(channels))
            }), info.0 > 0 else { return nil }
            let codec: String
            switch info.1 {
            case kAudioFormatLinearPCM: codec = ["aif", "aiff", "aifc"].contains((path as NSString).pathExtension.lowercased()) ? "AIFF" : "무손실"
            case kAudioFormatFLAC: codec = "FLAC"
            case kAudioFormatAppleLossless: codec = "ALAC"
            default: return nil
            }
            let est = levels.map { clamp(Double(audioBitrate($0, channels: info.2)) * info.0 / 8 + 20_000) }
            return Item(kind: kind, path: shown, size: size, estimates: est, detail: Fmt2.duration(info.0) + " · " + codec)

        case .pdf:
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else { return nil }
            // 아주 작은 PDF는 줄일 게 거의 없다
            if size < 300_000 { return nil }
            return Item(kind: kind, path: shown, size: size, estimates: levels.map { clamp(Double(size) * $0.pdfFactor) },
                        detail: "\(doc.pageCount)쪽")

        }
    }

    // MARK: - 줄이기

    public typealias Progress = @Sendable (_ fraction: Double, _ name: String) -> Void

    public static func apply(_ report: Report, kinds: Set<Kind>, level: Level, hevc: Bool = false, mode: SendPrep.Mode,
                             progress: Progress? = nil, cancel: CancelToken? = nil) throws -> Outcome {
        var outcome = Outcome()
        outcome.before = report.totalBytes
        let work = report.items.filter { kinds.contains($0.kind) }
        let totalWork = Double(max(1, work.reduce(0) { $0 + $1.size }))
        var doneWork = 0.0

        func process(_ node: Node, into dst: String?) throws {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            if node.walksInside {
                if let dst {
                    try POSIX.mkdir(dst)
                    for child in node.children { try process(child, into: dst + "/" + child.name.precomposedStringWithCanonicalMapping) }
                } else {
                    for child in node.children { try process(child, into: nil) }
                }
                return
            }
            guard let item = node.item, let kind = node.kind, kinds.contains(kind) else {
                if let dst { try POSIX.copy(node.path, dst, recursive: true) }
                outcome.after += node.size
                return
            }
            let report: (Double) -> Void = { f in
                progress?((doneWork + f * Double(item.size)) / totalWork, (item.path as NSString).lastPathComponent)
            }
            report(0)
            let dir = dst.map { ($0 as NSString).deletingLastPathComponent } ?? (node.path as NSString).deletingLastPathComponent
            let outExt = outputExtension(node.name, kind: kind)
            let tmp = dir + "/.finderie-\(UUID().uuidString)." + outExt
            var made: UInt64?
            do {
                try shrink(node.path, to: tmp, kind: kind, level: level, hevc: hevc, progress: report, cancel: cancel)
                var st = stat()
                if lstat(tmp, &st) == 0 { made = UInt64(st.st_size) }
            } catch ZipError.cancelled {
                unlink(tmp)
                throw ZipError.cancelled
            } catch {
                unlink(tmp)
                outcome.failed.append(item.path + ": " + error.localizedDescription)
            }
            doneWork += Double(item.size)

            // 5% 넘게 줄었을 때만 바꾼다
            if let made, Double(made) < Double(node.size) * 0.95 {
                let base = (node.name as NSString).deletingPathExtension
                let sameExt = (node.name as NSString).pathExtension.lowercased() == outExt
                let wanted = (sameExt ? node.name : base + "." + outExt).precomposedStringWithCanonicalMapping
                if let dst {
                    let target = free(((dst as NSString).deletingLastPathComponent) + "/" + wanted)
                    try POSIX.rename(tmp, target)
                } else {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: &trashed)
                    if let t = trashed as URL? { outcome.trashed.append(t) }
                    try POSIX.rename(tmp, sameExt ? node.path : free(dir + "/" + wanted))
                }
                outcome.after += made
                outcome.shrunk += 1
            } else {
                unlink(tmp)
                if let dst { try POSIX.copy(node.path, dst, recursive: false) }
                outcome.after += node.size
                if made != nil { outcome.kept += 1 }
            }
        }

        switch mode {
        case .copy:
            let parent = report.roots[0].deletingLastPathComponent().path
            let folder = free(parent + "/용량 줄인 파일")
            try POSIX.mkdir(folder)
            outcome.folder = URL(fileURLWithPath: folder)
            for root in report.tree {
                let dst = free(folder + "/" + root.name.precomposedStringWithCanonicalMapping)
                try process(root, into: dst)
                // 맨 위가 파일이면 확장자가 바뀌었을 수 있다
                let made = POSIX.list(folder).filter { !$0.hasPrefix(".") }
                outcome.items = made.map { URL(fileURLWithPath: folder + "/" + $0) }
            }
        case .inPlace:
            for root in report.tree { try process(root, into: nil) }
            outcome.items = report.roots
        }
        progress?(1, "")
        return outcome
    }

    static func outputExtension(_ name: String, kind: Kind) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch kind {
        case .photo: return ["tif", "tiff", "bmp"].contains(ext) ? "jpg" : ext
        case .video: return "mp4"
        case .audio: return "m4a"
        case .pdf: return ext
        }
    }

    static func shrink(_ src: String, to dst: String, kind: Kind, level: Level, hevc: Bool,
                       progress: (Double) -> Void, cancel: CancelToken?) throws {
        switch kind {
        case .photo: try shrinkPhoto(src, to: dst, level: level)
        case .video:
            guard let info = videoInfo(src) else { throw SendPrep.Failure(message: "영상을 읽지 못했어요") }
            let plan = VideoPlan(size: info.size, fps: info.fps,
                                 screen: isScreenRecording((src as NSString).lastPathComponent), level: level, hevc: hevc)
            try encodeVideo(src, to: dst, plan: plan, hevc: hevc, progress: progress, cancel: cancel)
        case .audio: try encodeAAC(src, to: dst, bitrate: level.audioBitrate, progress: progress, cancel: cancel)
        case .pdf: try shrinkPDF(src, to: dst, level: level)
        }
    }

    // MARK: 사진

    /// 긴 변을 줄이고 화질을 낮춘다. 사진 정보(EXIF)는 그대로 두고 방향은 실제 픽셀에 적용한다.
    static func shrinkPhoto(_ src: String, to dst: String, level: Level) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw SendPrep.Failure(message: "사진을 읽지 못했어요") }
        let edge = min(level.photoEdge, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SendPrep.Failure(message: "사진을 줄이지 못했어요")
        }
        let ext = (dst as NSString).pathExtension.lowercased()
        let type: UTType
        switch ext {
        case "png": type = .png
        case "heic", "heif": type = .heic
        case "avif": type = UTType("public.avif") ?? .jpeg
        case "webp":
            // macOS는 WebP를 저장하지 못해서 libwebp로 쓴다 (사진 정보는 담지 않는다)
            try Convert.writeWebP(image, to: dst, quality: level.photoQuality, lossless: false)
            return
        default: type = .jpeg
        }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, type.identifier as CFString, 1, nil) else {
            throw SendPrep.Failure(message: "사진을 저장하지 못했어요")
        }
        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta.removeValue(forKey: kCGImagePropertyPixelWidth)
        meta.removeValue(forKey: kCGImagePropertyPixelHeight)
        if type != .png { meta[kCGImageDestinationLossyCompressionQuality] = level.photoQuality }
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SendPrep.Failure(message: "사진을 저장하지 못했어요") }
    }

    // MARK: 영상 · 소리

    /// 단계 비트레이트를 채널 수에 맞춘다 (모노는 절반)
    static func audioBitrate(_ level: Level, channels: Int) -> Int {
        channels <= 1 ? level.audioBitrate / 2 : level.audioBitrate
    }

    /// 무손실 소리를 AAC(m4a)로. 48kHz 넘는 고해상도는 48kHz로, 3채널 이상은 스테레오로 낮춘다.
    /// 곡 정보(제목·가수·앨범·표지)는 그대로 옮긴다.
    static func encodeAAC(_ src: String, to dst: String, bitrate: Int,
                          progress: (Double) -> Void, cancel: CancelToken?) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        guard let (track, duration, metadata, rate, channels) = blocking({ () async throws -> (AVAssetTrack, Double, [AVMetadataItem], Double, Int)? in
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let format = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
            return (track, try await asset.load(.duration).seconds, try await asset.load(.metadata),
                    asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
        }) ?? nil else {
            throw SendPrep.Failure(message: "소리를 읽지 못했어요")
        }
        let outRate = rate > 48_000 ? 48_000 : (rate >= 44_100 ? rate : 44_100)
        let outChannels = min(max(channels, 1), 2)
        var pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: outChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = outChannels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        if channels > 2 { pcm[AVChannelLayoutKey] = layoutData }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: dst), fileType: .m4a)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: outChannels,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: outChannels == 1 ? bitrate / 2 : bitrate,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw SendPrep.Failure(message: "소리를 인코딩하지 못했어요")
        }
        writer.startSession(atSourceTime: .zero)
        while true {
            if cancel?.isCancelled == true {
                reader.cancelReading()
                writer.cancelWriting()
                throw ZipError.cancelled
            }
            guard input.isReadyForMoreMediaData else { usleep(2_000); continue }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if !input.append(buffer) { break }
            if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard reader.status == .completed, writer.status == .completed else {
            throw SendPrep.Failure(message: writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "소리를 인코딩하지 못했어요")
        }
    }

    // MARK: PDF

    static func shrinkPDF(_ src: String, to dst: String, level: Level) throws {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: src)), !doc.isLocked else {
            throw SendPrep.Failure(message: "PDF를 열지 못했어요")
        }
        // macOS 미리보기의 '파일 크기 줄이기' 필터와 같은 방식으로, 단계마다 이미지 해상도와 화질을 정한다
        let (quality, dpi, maxSize): (Double, Int, Int) = [(0.85, 300, 3600), (0.7, 200, 2400), (0.5, 144, 1600)][level.rawValue]
        let settings: [String: Any] = [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Finderie",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true,
                                       "ImageSizeMax": maxSize, "ImageSizeMin": 0],
            ]]],
        ]
        guard let filter = QuartzFilter(properties: settings) else { throw SendPrep.Failure(message: "PDF 필터를 만들지 못했어요") }
        let options: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]
        guard doc.write(to: URL(fileURLWithPath: dst), withOptions: options) else {
            throw SendPrep.Failure(message: "PDF를 저장하지 못했어요")
        }
    }

    // MARK: Office 문서


    // MARK: 도움

    /// 비어 있는 경로 (있으면 " 2", " 3"…)
    static func free(_ path: String) -> String {
        guard POSIX.inode(path) != nil else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = dir + "/" + (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if POSIX.inode(candidate) == nil { return candidate }
            n += 1
        }
    }

    static func display(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: ":", with: "/")
    }

    /// async API(AVFoundation)를 검사 스레드에서 기다린다
    static func blocking<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) -> T? {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await op()
            done.signal()
        }
        done.wait()
        return box.value
    }
}

final class BlockingBox<T>: @unchecked Sendable { var value: T? }

enum Fmt2 {
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)초" }
        if t < 3600 { return "\(t / 60)분 \(t % 60)초" }
        return "\(t / 3600)시간 \(t / 60 % 60)분"
    }

    static func resolution(_ size: CGSize) -> String {
        let short = min(size.width, size.height)
        if short >= 2000 { return "4K" }
        if short >= 1000 { return "1080p" }
        if short >= 700 { return "720p" }
        return "\(Int(short))p"
    }
}
