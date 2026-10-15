// 시험용 4K H.264 영상을 만든다 (움직이는 그라데이션 + 사인파 소리 없음, 높은 비트레이트)
//   swift make_video.swift <출력.mov> [초]
import AVFoundation
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 8 : 8
try? FileManager.default.removeItem(at: out)
let w = 3840, h = 2160, fps = 30
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 45_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
var noise = SystemRandomNumberGenerator()
for i in 0..<(seconds * fps) {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let t = CGFloat(i) / CGFloat(fps)
    let g = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.2, green: 0.6 + 0.3 * sin(t), blue: 0.95, alpha: 1),
                                                   CGColor(red: 0.95, green: 0.5, blue: 0.3 + 0.3 * cos(t), alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(w), y: CGFloat(h) * (0.5 + 0.5 * sin(t))), options: [])
    // 잔 무늬를 뿌려 실제 영상처럼 비트레이트를 쓰게 한다
    for _ in 0..<4000 {
        ctx.setFillColor(CGColor(gray: CGFloat.random(in: 0...1, using: &noise), alpha: 0.5))
        ctx.fill(CGRect(x: Int.random(in: 0..<w, using: &noise), y: Int.random(in: 0..<h, using: &noise), width: 6, height: 6))
    }
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "ok" : "fail \(String(describing: writer.error))")
