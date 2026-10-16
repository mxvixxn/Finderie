import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// 보내기 전에 지울 개인정보: 사진의 위치·기기 정보, 영상의 촬영 위치, 문서의 작성자.
/// 사진과 영상은 다시 압축하지 않고 정보만 빼서 화질이 그대로다.
enum Privacy {
    enum Format {
        case photo, video, pdf, office

        static func of(_ name: String) -> Format? {
            switch (name as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng": return .photo
            case "mov", "mp4", "m4v": return .video
            case "pdf": return .pdf
            case "docx", "pptx", "xlsx": return .office
            default: return nil
            }
        }
    }

    struct Finding {
        let kind: SendPrep.IssueKind
        let note: String?
    }

    // MARK: 찾기

    static func inspect(_ path: String) -> [Finding] {
        guard let format = Format.of(path) else { return [] }
        switch format {
        case .photo: return inspectPhoto(path)
        case .video: return inspectVideo(path)
        case .pdf: return inspectPDF(path)
        case .office: return inspectOffice(path)
        }
    }

    private static func inspectPhoto(_ path: String) -> [Finding] {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var out: [Finding] = []
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], gps[kCGImagePropertyGPSLatitude] != nil {
            out.append(Finding(kind: .photoLocation, note: nil))
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let device = [tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel]].compactMap { $0 as? String }
            .filter { !$0.isEmpty }
        let serial = exif[kCGImagePropertyExifBodySerialNumber] ?? exif[kCGImagePropertyExifCameraOwnerName]
        if !device.isEmpty || serial != nil {
            out.append(Finding(kind: .photoDevice, note: device.isEmpty ? nil : device.joined(separator: " ")))
        }
        return out
    }

    private static func inspectVideo(_ path: String) -> [Finding] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let items = blocking({ try await asset.load(.metadata) }) else { return [] }
        let keys = items.compactMap { $0.identifier?.rawValue.lowercased() }
        return keys.contains(where: { $0.contains("location") }) ? [Finding(kind: .videoLocation, note: nil)] : []
    }

    private static func inspectPDF(_ path: String) -> [Finding] {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked,
              let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
              !author.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return [Finding(kind: .documentAuthor, note: author)]
    }

    private static func inspectOffice(_ path: String) -> [Finding] {
        guard let core = unzipEntry(path, "docProps/core.xml") else { return [] }
        let app = unzipEntry(path, "docProps/app.xml") ?? ""
        let names = [tag("dc:creator", in: core), tag("cp:lastModifiedBy", in: core), tag("Company", in: app)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        return [Finding(kind: .documentAuthor, note: Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", "))]
    }

    // MARK: 지우기

    /// src의 개인정보를 뺀 사본을 dst에 만든다. dst는 영문 임시 경로여야 한다 (Foundation이 한글을 자모로 풀어 쓴다).
    static func strip(_ src: String, to dst: String) throws {
        guard let format = Format.of(src) else { throw SendPrep.Failure(message: "지원하지 않는 파일이에요") }
        switch format {
        case .photo: try stripPhoto(src, to: dst)
        case .video: try stripVideo(src, to: dst)
        case .pdf: try stripPDF(src, to: dst)
        case .office: try stripOffice(src, to: dst)
        }
    }

    /// 다시 압축하지 않고 메타데이터만 바꿔 쓴다 (CGImageDestinationCopyImageSource)
    static func stripPhoto(_ src: String, to dst: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, type, 1, nil)
        else { throw SendPrep.Failure(message: "사진을 읽지 못했어요") }
        let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        for path in ["tiff:Make", "tiff:Model", "tiff:Software", "tiff:Artist", "tiff:HostComputer",
                     "exifEX:LensMake", "exifEX:LensModel", "exifEX:BodySerialNumber", "exifEX:LensSerialNumber",
                     "exifEX:CameraOwnerName", "aux:SerialNumber", "aux:Lens", "exif:MakerNote"] {
            CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            throw SendPrep.Failure(message: "사진 정보를 지우지 못했어요")
        }
    }

    /// 다시 인코딩하지 않고(passthrough) 위치·개인 정보 태그만 뺀다
    static func stripVideo(_ src: String, to dst: String) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SendPrep.Failure(message: "영상을 열지 못했어요")
        }
        session.outputURL = URL(fileURLWithPath: dst)
        session.outputFileType = (dst as NSString).pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.metadataItemFilter = .forSharing()
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            throw SendPrep.Failure(message: session.error?.localizedDescription ?? "영상 정보를 지우지 못했어요")
        }
    }

    static func stripPDF(_ src: String, to dst: String) throws {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: src)), !doc.isLocked else {
            throw SendPrep.Failure(message: "PDF를 열지 못했어요")
        }
        var attrs = doc.documentAttributes ?? [:]
        attrs.removeValue(forKey: PDFDocumentAttribute.authorAttribute)
        doc.documentAttributes = attrs
        guard doc.write(to: URL(fileURLWithPath: dst)) else { throw SendPrep.Failure(message: "PDF를 저장하지 못했어요") }
    }

    /// docProps의 작성자·마지막 수정자·회사 이름을 비우고 다시 묶는다
    static func stripOffice(_ src: String, to dst: String) throws {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "finderie-props-\(UUID().uuidString)"
        try POSIX.mkdir(work)
        defer { try? fm.removeItem(atPath: work) }
        try run("/usr/bin/ditto", ["-x", "-k", src, work])
        for (file, tags) in [("docProps/core.xml", ["dc:creator", "cp:lastModifiedBy"]),
                             ("docProps/app.xml", ["Company", "Manager"])] {
            let path = work + "/" + file
            guard var xml = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for t in tags {
                // <dc:creator>이름</dc:creator> → <dc:creator></dc:creator>
                xml = xml.replacingOccurrences(of: "<\(t)>[^<]*</\(t)>", with: "<\(t)></\(t)>", options: .regularExpression)
            }
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", work, dst])
    }

    // MARK: 도움

    private static func unzipEntry(_ zip: String, _ entry: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", zip, entry]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "<\(name)>([^<]*)</\(name)>", options: .regularExpression) else { return nil }
        return String(xml[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SendPrep.Failure(message: "문서를 다시 묶지 못했어요") }
    }

    private static func blocking<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) -> T? {
        let box = PrivacyBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await op()
            done.signal()
        }
        done.wait()
        return box.value
    }
}

final class PrivacyBox<T>: @unchecked Sendable { var value: T? }
