import AVFoundation
import VideoToolbox

/// Encodes a built composition at fixed bitrates so the file lands near `ExportSettings.targetFileSize`.
///
/// AVAssetExportSession presets have no bitrate control, so this renders through
/// AVAssetReader (video composition + audio mix outputs) into an AVAssetWriter whose encoders get
/// the average bitrates from `ExportSettings.bitRates(duration:hasAudio:)`. One pass: the size is an
/// estimate, and footage the encoder can't squeeze to that rate (very noisy video, especially with
/// H.264) comes out bigger.
enum TargetSizeExport {
    static func run(_ built: BuiltComposition, settings: ExportSettings, frameRate: Double, to url: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = built.composition
        let duration = built.duration
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let rates = settings.bitRates(duration: duration, hasAudio: !audioTracks.isEmpty) else {
            throw EngineError.exportFailed("Nothing to export")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: CompositionBuilder.timescale))
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: url, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = settings.container == .mp4
        let renderSize = built.videoComposition.renderSize
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: rates.video,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            // The average is only a hint (hard-to-compress footage overshoots it several times);
            // this caps every second of video at that rate.
            kVTCompressionPropertyKey_DataRateLimits as String: [rates.video * 3 / 16, 1],
        ]
        compression[AVVideoProfileLevelKey] = settings.codec == .h264
            ? AVVideoProfileLevelH264HighAutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel as String
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audio: (out: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: rates.audio,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = (out, input)
        }

        guard reader.startReading() else {
            throw EngineError.exportFailed(reader.error?.localizedDescription ?? "Can't read the composition")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "Can't write the movie")
        }
        writer.startSession(atSourceTime: .zero)

        let cancelled = Flag()
        // AVAssetReader/Writer are thread-safe for cancellation.
        nonisolated(unsafe) let cancellableReader = reader, cancellableWriter = writer
        let videoPump = Pump(), audioPump = Pump()
        try await withTaskCancellationHandler {
            async let videoDone: Void = videoPump.run(videoOut, into: videoIn, label: "video") { time in
                progress(min(1, max(0, time.seconds / duration)))
            }
            if let audio {
                await audioPump.run(audio.out, into: audio.input, label: "audio", onSample: nil)
            }
            await videoDone

            if cancelled.isSet { throw CancellationError() }
            if reader.status == .failed {
                writer.cancelWriting()
                throw EngineError.exportFailed(reader.error?.localizedDescription ?? "Rendering failed")
            }
            await writer.finishWriting()
            if writer.status != .completed {
                throw EngineError.exportFailed(writer.error?.localizedDescription ?? "Encoding failed")
            }
        } onCancel: {
            cancelled.set()
            videoPump.stop()
            audioPump.stop()
            cancellableReader.cancelReading()
            cancellableWriter.cancelWriting()
        }
    }

    /// Feeds a reader output's samples to a writer input until the reader runs out, the writer fails
    /// or `stop()` is called. A cancelled writer stops asking for data, so `stop()` ends the wait
    /// itself instead of relying on the input's callback.
    private final class Pump: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false

        private var isDone: Bool { lock.withLock { done } }

        func run(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                 onSample: ((CMTime) -> Void)?) async {
            // Only touched on the input's serial request queue.
            nonisolated(unsafe) let input = input, output = output
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let stopped = lock.withLock {
                    if !done { self.continuation = continuation }
                    return done
                }
                if stopped { return continuation.resume() }
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "EditRush.TargetSizeExport.\(label)")) { [self] in
                    while !isDone, input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            if !isDone { input.markAsFinished() }
                            return stop()
                        }
                        onSample?(sample.presentationTimeStamp)
                        // On failure the writer is done; finishWriting reports its error.
                        if !input.append(sample) { return stop() }
                    }
                }
            }
        }

        /// Ends `run`; safe to call from any thread, any number of times, before or during `run`.
        func stop() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { done = true; self.continuation = nil }
                return done ? nil : self.continuation
            }
            continuation?.resume()
        }
    }

    /// One-way thread-safe boolean.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
