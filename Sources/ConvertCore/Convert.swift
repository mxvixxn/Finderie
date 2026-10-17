import AppKit
import CWebP
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZipCore

/// 사진 형식 바꾸기: JPG · PNG · HEIC · WebP · AVIF · TIFF 사이, 그리고 SVG를 그림으로.
///
/// 1. scan으로 바꿀 수 있는 사진을 찾는다 (폴더 안까지).
/// 2. apply로 "형식 바꾼 사진" 폴더에 새 파일을 만든다. 원본은 건드리지 않는다.
///
/// macOS는 WebP를 읽기만 하므로, WebP로 저장할 때는 함께 넣은 libwebp를 쓴다.
/// 새 파일은 영문 임시 이름으로 만든 뒤 POSIX로 옮긴다 (ImageIO는 한글 경로를 자모로 풀어 쓴다).
public enum Convert {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpg, png, heic, webp, avif, tiff
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .jpg: return "JPG"
            case .png: return "PNG"
            case .heic: return "HEIC"
            case .webp: return "WebP"
            case .avif: return "AVIF"
            case .tiff: return "TIFF"
            }
        }

        var type: UTType? {
            switch self {
            case .jpg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            case .webp: return nil
            case .avif: return UTType("public.avif")
            case .tiff: return .tiff
            }
        }

        /// 투명한 부분을 담을 수 있는지
        public var keepsAlpha: Bool { self != .jpg }

        static func of(_ ext: String) -> Format? {
            switch ext {
            case "jpg", "jpeg": return .jpg
            case "png": return .png
            case "heic", "heif": return .heic
            case "webp": return .webp
            case "avif": return .avif
            case "tif", "tiff": return .tiff
            default: return nil
            }
        }
    }

    /// 읽을 수 있는 확장자
    static let readable: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff",
                                        "gif", "bmp", "svg"]

    public struct Item: Identifiable, Sendable {
        public let id = UUID()
        public let path: String
        /// 고른 항목 기준 상대 경로 (화면용, 만들 파일의 자리)
        public let shown: String
        public let size: UInt64
        /// "HEIC", "SVG" 같은 원래 형식
        public let kind: String
    }

    public struct Outcome: Sendable {
        public var folder: URL?
        public var made = 0
        /// 이미 그 형식이라 그대로 복사한 파일
        public var same = 0
        public var before: UInt64 = 0
        public var after: UInt64 = 0
        public var failed: [String] = []
    }

    public typealias Progress = @Sendable (Double, String) -> Void

    // MARK: 찾기

    public static func scan(_ urls: [URL], cancel: CancelToken? = nil) throws -> [Item] {
        var items: [Item] = []
        let fm = FileManager.default
        func add(_ url: URL, shown: String) {
            let ext = url.pathExtension.lowercased()
            guard readable.contains(ext) else { return }
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            items.append(Item(path: url.path, shown: shown.precomposedStringWithCanonicalMapping,
                              size: size, kind: ext == "jpeg" ? "JPG" : ext == "heif" ? "HEIC" : ext == "tif" ? "TIFF" : ext.uppercased()))
        }
        for root in urls {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { add(root, shown: root.lastPathComponent); continue }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if cancel?.isCancelled == true { throw ZipError.cancelled }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                let rel = String(url.path.dropFirst(root.path.count + 1))
                add(url, shown: root.lastPathComponent + "/" + rel)
            }
        }
        return items
    }

    // MARK: 바꾸기

    public static func apply(_ items: [Item], roots: [URL], to format: Format, quality: Double = 0.9,
                             progress: Progress? = nil, cancel: CancelToken? = nil) throws -> Outcome {
        var outcome = Outcome()
        guard let first = roots.first else { return outcome }
        let folder = free(first.deletingLastPathComponent().path + "/형식 바꾼 사진")
        try POSIX.mkdir(folder)
        outcome.folder = URL(fileURLWithPath: folder)

        for (i, item) in items.enumerated() {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            progress?(Double(i) / Double(max(1, items.count)), (item.shown as NSString).lastPathComponent)
            outcome.before += item.size

            // 폴더 구조를 그대로 따라 만든다
            let relDir = (item.shown as NSString).deletingLastPathComponent
            let dir = relDir.isEmpty ? folder : folder + "/" + relDir
            try mkdirs(dir)
            let base = ((item.shown as NSString).lastPathComponent as NSString).deletingPathExtension
            let ext = (item.path as NSString).pathExtension.lowercased()

            if Format.of(ext) == format {
                let target = free(dir + "/" + (item.shown as NSString).lastPathComponent)
                try POSIX.copy(item.path, target, recursive: false)
                outcome.same += 1
                outcome.after += item.size
                continue
            }

            let tmp = dir + "/.finderie-\(UUID().uuidString).\(format.rawValue)"
            do {
                try convert(item.path, to: tmp, format: format, quality: quality)
                var st = stat()
                if lstat(tmp, &st) == 0 { outcome.after += UInt64(st.st_size) }
                try POSIX.rename(tmp, free(dir + "/" + base + "." + format.rawValue))
                outcome.made += 1
            } catch {
                unlink(tmp)
                outcome.failed.append(item.shown + ": " + error.localizedDescription)
            }
        }
        progress?(1, "")
        return outcome
    }

    /// 사진 하나를 바꾼다. 방향은 실제 픽셀에 적용하고, 사진 정보(EXIF·GPS)는 담을 수 있는 형식이면 그대로 둔다.
    static func convert(_ src: String, to dst: String, format: Format, quality: Double) throws {
        let (image, props) = try load(src)
        let flat = format.keepsAlpha ? image : try flatten(image)

        if format == .webp {
            try writeWebP(flat, to: dst, quality: quality, lossless: hasAlphaOrIsGraphic(src))
            return
        }
        guard let type = format.type,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure("이 Mac에서는 \(format.title)로 저장할 수 없어요")
        }
        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta.removeValue(forKey: kCGImagePropertyPixelWidth)
        meta.removeValue(forKey: kCGImagePropertyPixelHeight)
        if [.jpg, .heic, .avif].contains(format) { meta[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, flat, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure("\(format.title)로 저장하지 못했어요") }
    }

    /// 그림을 읽는다. SVG는 긴 변이 1024px 이상이 되게 그린다. 움직이는 GIF·WebP는 첫 장면만 쓴다.
    static func load(_ src: String) throws -> (CGImage, [CFString: Any]) {
        let url = URL(fileURLWithPath: src)
        if url.pathExtension.lowercased() == "svg" {
            guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
                throw Failure("SVG를 읽지 못했어요")
            }
            let scale = max(2, 1024 / max(svg.size.width, svg.size.height))
            let w = Int((svg.size.width * scale).rounded()), h = Int((svg.size.height * scale).rounded())
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure("SVG를 그리지 못했어요")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let image = ctx.makeImage() else { throw Failure("SVG를 그리지 못했어요") }
            return (image, [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure("사진을 읽지 못했어요")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure("사진을 읽지 못했어요")
        }
        return (image, props)
    }

    /// 투명한 부분을 흰 바탕 위에 올린다 (JPG용)
    static func flatten(_ image: CGImage) throws -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure("사진을 그리지 못했어요") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw Failure("사진을 그리지 못했어요") }
        return out
    }

    /// PNG · GIF · SVG · BMP처럼 그래픽에 가까운 원본은 WebP도 무손실로 만든다
    static func hasAlphaOrIsGraphic(_ src: String) -> Bool {
        ["png", "gif", "svg", "bmp"].contains((src as NSString).pathExtension.lowercased())
    }

    public static func writeWebP(_ image: CGImage, to dst: String, quality: Double, lossless: Bool) throws {
        let w = image.width, h = image.height
        let stride = w * 4
        var pixels = [UInt8](repeating: 0, count: stride * h)
        // libwebp는 곱하지 않은(straight) RGBA를 받는다
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure("사진을 그리지 못했어요") }
        for i in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0 && a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buf -> Int in
            lossless
                ? WebPEncodeLosslessRGBA(buf.baseAddress, Int32(w), Int32(h), Int32(stride), &output)
                : WebPEncodeRGBA(buf.baseAddress, Int32(w), Int32(h), Int32(stride), Float(quality * 100), &output)
        }
        guard size > 0, let output else { throw Failure("WebP로 저장하지 못했어요") }
        defer { WebPFree(output) }
        try POSIX.write(Data(bytes: output, count: size), to: dst)
    }

    // MARK: 도움

    public struct Failure: LocalizedError {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// 없는 폴더를 차례로 만든다. FileManager는 이름을 자모로 풀어 쓰므로 POSIX로 만든다.
    static func mkdirs(_ path: String) throws {
        guard POSIX.inode(path) == nil else { return }
        try mkdirs((path as NSString).deletingLastPathComponent)
        try POSIX.mkdir(path)
    }

    /// 비어 있는 경로 (있으면 " 2", " 3"…)
    static func free(_ path: String) -> String {
        guard POSIX.inode(path) == nil else {
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
        return path
    }
}
