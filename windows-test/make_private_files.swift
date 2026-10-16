// 개인정보가 들어 있는 시험 파일을 만든다: swift make_private_files.swift <폴더>
//   위치 사진.jpg (GPS + 카메라 정보), 계약서.pdf (작성자), 현장 영상.mov (촬영 위치)
import AVFoundation
import AppKit
import ImageIO
import PDFKit

let dir = CommandLine.arguments[1]
func tmp(_ ext: String) -> URL { URL(fileURLWithPath: dir + "/.make-\(UUID().uuidString).\(ext)") }
func place(_ url: URL, as name: String) { rename(url.path, dir + "/" + name) }   // 한글 이름을 NFC 그대로

// 작은 그림
let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
let image = ctx.makeImage()!

// 1. 위치 사진
let photo = tmp("jpg")
let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, [
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5665, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 126.978, kCGImagePropertyGPSLongitudeRef: "E"],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "F2LXK0001", kCGImagePropertyExifDateTimeOriginal: "2026:10:01 10:00:00"],
] as CFDictionary)
CGImageDestinationFinalize(dest)
place(photo, as: "위치 사진.jpg")

// 2. 작성자가 적힌 PDF
let doc = PDFDocument()
doc.insert(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 640, height: 480)))!, at: 0)
doc.documentAttributes = [PDFDocumentAttribute.authorAttribute: "김철수", PDFDocumentAttribute.titleAttribute: "계약서"]
let pdf = tmp("pdf")
doc.write(to: pdf)
place(pdf, as: "계약서.pdf")

// 3. 촬영 위치가 든 짧은 영상
let mov = tmp("mov")
let writer = try! AVAssetWriter(outputURL: mov, fileType: .mov)
let loc = AVMutableMetadataItem()
loc.identifier = .quickTimeMetadataLocationISO6709
loc.value = "+37.5665+126.9780+030.000/" as NSString
loc.dataType = kCMMetadataBaseDataType_UTF8 as String
writer.metadata = [loc]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for i in 0..<30 {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buf: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buf)
    CVPixelBufferLockBaseAddress(buf!, [])
    memset(CVPixelBufferGetBaseAddress(buf!), Int32(i * 8), CVPixelBufferGetDataSize(buf!))
    CVPixelBufferUnlockBaseAddress(buf!, [])
    adaptor.append(buf!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
place(mov, as: "현장 영상.mov")
print("ok")
