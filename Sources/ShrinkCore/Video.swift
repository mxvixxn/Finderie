import AVFoundation
import Foundation
import ZipCore

// 영상 줄이기: AVAssetReader로 읽고 AVAssetWriter로 다시 쓴다.
// 내보내기 프리셋은 HEVC 720p·540p가 없고 프레임 수도 못 바꿔서 직접 인코딩한다.

extension Shrink {
    /// 영상 하나를 어떻게 줄일지 (원본 정보 + 단계 → 크기·프레임 수·비트레이트)
    struct VideoPlan {
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
        static let audioBitrate = 128_000

        /// 화면 녹화는 글씨가 뭉개지지 않게 해상도를 덜 줄이고, 프레임 수를 30으로 낮춘다
        init(size: CGSize, fps sourceFPS: Double, screen: Bool, level: Level, hevc: Bool) {
            let longCap = screen ? [3840, 2560, 1920][level.rawValue] : [1920, 1280, 960][level.rawValue]
            let long = max(size.width, size.height)
            let scale = min(1, Double(longCap) / Double(max(long, 1)))
            func even(_ v: Double) -> Int { max(2, Int((v * scale / 2).rounded()) * 2) }
            width = even(size.width)
            height = even(size.height)
            let source = sourceFPS > 1 ? sourceFPS : 30
            fps = Int(min(source, screen ? 30 : 60).rounded())
            // 화소 하나·장면 하나에 쓰는 비트 수. 화면 녹화는 대부분 멈춰 있어서 절반이면 된다
            var bpp = [0.12, 0.085, 0.065][level.rawValue] * (screen ? 0.5 : 1)
            if hevc { bpp *= 0.6 }
            bitrate = max(400_000, Int(Double(width * height * fps) * bpp))
        }

        func estimate(duration: Double) -> Double {
            Double(bitrate + Self.audioBitrate) * duration / 8
        }

        var label: String {
            let short = min(width, height)
            return short >= 2000 ? "4K" : "\(short)p"
        }
    }

    /// 파일 이름으로 화면 녹화인지 알아본다 (macOS · iPhone · CleanShot 기본 이름)
    static func isScreenRecording(_ name: String) -> Bool {
        let n = name.precomposedStringWithCanonicalMapping.lowercased()
        return ["화면 기록", "화면 녹화", "screen recording", "cleanshot", "rpreplay"].contains { n.hasPrefix($0) || n.contains($0) }
    }

    /// 영상 정보 (방향을 적용한 크기, 프레임 수, 길이)
    static func videoInfo(_ path: String) -> (size: CGSize, fps: Double, duration: Double)? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        return blocking({ () async throws -> (CGSize, Double, Double)? in
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let r = natural.applying(transform)
            return (CGSize(width: abs(r.width), height: abs(r.height)), Double(fps), duration)
        }) ?? nil
    }

    static func encodeVideo(_ src: String, to dst: String, plan: VideoPlan, hevc: Bool,
                            progress: (Double) -> Void, cancel: CancelToken?) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        guard let loaded = blocking({ () async throws -> (AVAssetTrack, AVAssetTrack?, Double, [AVMetadataItem], AVMutableVideoComposition)? in
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            return (video, audio, try await asset.load(.duration).seconds, try await asset.load(.metadata), composition)
        }) ?? nil else {
            throw SendPrep.Failure(message: "영상을 읽지 못했어요")
        }
        let (videoTrack, audioTrack, duration, metadata, composition) = loaded
        // 방향을 바로 세우고, 프레임 수를 맞추고, HDR은 보통 화면(SDR) 색으로 바꾼다
        // 원본 트랙의 장면 시각을 따르면 frameDuration이 무시되므로 끊는다
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: dst), fileType: .mp4)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitrate,
            AVVideoExpectedSourceFrameRateKey: plan.fps,
            AVVideoMaxKeyFrameIntervalKey: plan.fps * 2,
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(out)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                AVEncoderBitRateKey: VideoPlan.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOut = out
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw SendPrep.Failure(message: reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "영상을 인코딩하지 못했어요")
        }
        writer.startSession(atSourceTime: .zero)

        // 영상과 소리를 각자 준비되는 대로 옮긴다
        let group = DispatchGroup()
        let lock = NSLock()
        var seconds = 0.0
        func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, tracksProgress: Bool) {
            group.enter()
            let queue = DispatchQueue(label: "finderie.video." + label)
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if cancel?.isCancelled == true || reader.status != .reading {
                        finished = true
                    } else if let buffer = output.copyNextSampleBuffer() {
                        if tracksProgress {
                            lock.lock(); seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds; lock.unlock()
                        }
                        if !input.append(buffer) { finished = true }
                    } else {
                        finished = true
                    }
                    if finished {
                        input.markAsFinished()
                        group.leave()
                    }
                }
            }
        }
        pump(videoOut, into: videoIn, label: "v", tracksProgress: true)
        if let audioOut, let audioIn { pump(audioOut, into: audioIn, label: "a", tracksProgress: false) }

        while group.wait(timeout: .now() + 0.25) == .timedOut {
            if cancel?.isCancelled == true { reader.cancelReading() }
            lock.lock(); let s = seconds; lock.unlock()
            if duration > 0 { progress(min(1, s / duration)) }
        }
        if cancel?.isCancelled == true {
            writer.cancelWriting()
            throw ZipError.cancelled
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard reader.status == .completed, writer.status == .completed else {
            throw SendPrep.Failure(message: writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "영상을 인코딩하지 못했어요")
        }
    }
}
