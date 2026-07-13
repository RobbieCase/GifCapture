import AVFoundation
import CoreGraphics

enum EditorLoopMode: String, CaseIterable, Sendable {
    case forward = "Forward"
    case reverse = "Reverse"
    case pingPong = "Ping-Pong"
}

enum EditorCropMode: String, CaseIterable, Sendable {
    case none = "No Crop"
    case square = "Square (1:1)"
    case landscape = "Landscape (16:9)"
    case classic = "Classic (4:3)"
    case portrait = "Portrait (9:16)"
    case custom = "Custom Crop"

    var aspectRatio: CGFloat? {
        switch self {
        case .none, .custom: return nil
        case .square: return 1
        case .landscape: return 16 / 9
        case .classic: return 4 / 3
        case .portrait: return 9 / 16
        }
    }
}

struct VideoEditOptions: Sendable {
    var startTime: Double
    var endTime: Double
    var frameRate: Double
    var cropMode: EditorCropMode
    var outputWidth: Int?
    var speed: Double
    var loopMode: EditorLoopMode
    var frameTimes: [Double]
    var customCrop: CGRect?

    init(
        startTime: Double,
        endTime: Double,
        frameRate: Double,
        cropMode: EditorCropMode,
        outputWidth: Int?,
        speed: Double,
        loopMode: EditorLoopMode,
        frameTimes: [Double] = [],
        customCrop: CGRect? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.frameRate = frameRate
        self.cropMode = cropMode
        self.outputWidth = outputWidth
        self.speed = speed
        self.loopMode = loopMode
        self.frameTimes = frameTimes
        self.customCrop = customCrop
    }

    var needsFrameExport: Bool {
        cropMode != .none || outputWidth != nil || speed != 1 || loopMode != .forward
    }
}

enum VideoEditorExporter {
    /// Reads compressed sample timestamps without decoding pixels. Imported GIFs
    /// can have uneven frame delays, so nominalFrameRate alone is not sufficient.
    static func frameTimeline(asset: AVAsset) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? editorError("Couldn't inspect video frames.") }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time.isFinite { times.append(time) }
        }
        // Compressed H.264 samples can arrive in decode order (B-frames), and
        // their track timeline may have a non-zero edit-list offset. Normalize
        // sorted unique presentation times back to the editor's zero origin.
        times.sort()
        var unique: [Double] = []
        for time in times where unique.last.map({ abs($0 - time) > 0.000_001 }) ?? true {
            unique.append(time)
        }
        guard let first = unique.first else { return [] }
        return unique.map { max(0, $0 - first) }
    }

    /// Builds an edited H.264 movie one source frame at a time. Generating by
    /// exact source timestamps makes reverse and ping-pong deterministic and
    /// keeps trim boundaries aligned to actual frames.
    static func export(asset: AVAsset, options: VideoEditOptions) async throws -> URL {
        let frameRate = max(1, options.frameRate)
        let sourceFrameDuration = 1 / frameRate
        let timeline = options.frameTimes.isEmpty
            ? stride(from: 0.0, to: options.endTime, by: sourceFrameDuration).map { $0 }
            : options.frameTimes
        var frameIndexes = timeline.indices.filter {
            timeline[$0] >= options.startTime - 0.000_001 && timeline[$0] < options.endTime - 0.000_001
        }
        if frameIndexes.isEmpty, let nearest = timeline.indices.min(by: {
            abs(timeline[$0] - options.startTime) < abs(timeline[$1] - options.startTime)
        }) {
            frameIndexes = [nearest]
        }
        guard !frameIndexes.isEmpty else { throw editorError("The selected range contains no frames.") }
        switch options.loopMode {
        case .forward:
            break
        case .reverse:
            frameIndexes.reverse()
        case .pingPong:
            if frameIndexes.count > 2 {
                frameIndexes += frameIndexes.dropFirst().dropLast().reversed()
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let firstImage = try await image(
            from: generator,
            at: CMTime(seconds: timeline[frameIndexes[0]], preferredTimescale: 60_000)
        )
        let crop = cropRect(for: firstImage, mode: options.cropMode, customCrop: options.customCrop)
        let requestedWidth = options.outputWidth.map { max(2, $0) } ?? Int(crop.width)
        let outputWidth = requestedWidth & ~1
        let outputHeight = max(2, Int((CGFloat(outputWidth) * crop.height / crop.width).rounded()) & ~1)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
            ]
        )
        guard writer.canAdd(input) else { throw editorError("Couldn't configure the edited video.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? editorError("Couldn't start the edited video.") }
        writer.startSession(atSourceTime: .zero)

        let speed = min(2, max(0.5, options.speed))
        let fallbackDuration: Double = {
            let intervals = zip(timeline.dropFirst(), timeline).map { $0.0 - $0.1 }.filter { $0 > 0 }
            guard !intervals.isEmpty else { return sourceFrameDuration }
            return intervals.sorted()[intervals.count / 2]
        }()
        var outputTime = 0.0
        for (outputIndex, sourceIndex) in frameIndexes.enumerated() {
            try Task.checkCancellation()
            let readyDeadline = Date().addingTimeInterval(60)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status != .failed && writer.status != .cancelled else {
                    throw writer.error ?? editorError("The edited video writer stopped unexpectedly.")
                }
                guard Date() < readyDeadline else {
                    writer.cancelWriting()
                    throw editorError("Timed out waiting to write edited frame \(outputIndex).")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let sourceTime = CMTime(seconds: timeline[sourceIndex], preferredTimescale: 60_000)
            let decodedImage = try await image(from: generator, at: sourceTime)
            guard let buffer = makePixelBuffer(
                image: decodedImage,
                cropMode: options.cropMode,
                customCrop: options.customCrop,
                width: outputWidth,
                height: outputHeight,
                pool: adaptor.pixelBufferPool
            ) else { throw editorError("Couldn't decode frame \(sourceIndex).") }
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(seconds: outputTime, preferredTimescale: 60_000)
            ) else { throw writer.error ?? editorError("Couldn't write frame \(outputIndex).") }
            let sourceDuration = sourceIndex + 1 < timeline.count
                ? max(0.001, timeline[sourceIndex + 1] - timeline[sourceIndex])
                : fallbackDuration
            outputTime += sourceDuration / speed
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            seconds: outputTime,
            preferredTimescale: 60_000
        ))
        let finishBox = WriterFinishBox(writer: writer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                finishBox.start(continuation)
            }
        } onCancel: {
            finishBox.cancel()
        }
        guard writer.status == .completed else {
            throw writer.error ?? editorError("Couldn't finish the edited video.")
        }
        return outputURL
    }

    private static func image(from generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        if #available(macOS 15.0, *) {
            return try await generator.image(at: time).image
        } else {
            return try legacyImage(from: generator, at: time)
        }
    }

    @available(macOS, introduced: 10.7, obsoleted: 15.0)
    private static func legacyImage(from generator: AVAssetImageGenerator, at time: CMTime) throws -> CGImage {
        var actual = CMTime.zero
        return try generator.copyCGImage(at: time, actualTime: &actual)
    }

    private static func cropRect(for image: CGImage, mode: EditorCropMode, customCrop: CGRect?) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if mode == .custom, let normalized = customCrop {
            let safe = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard safe.width >= 0.01, safe.height >= 0.01 else { return bounds }
            // AppKit's preview origin is bottom-left; CGImage crop coordinates
            // address rows from the top.
            return CGRect(
                x: safe.minX * bounds.width,
                y: (1 - safe.maxY) * bounds.height,
                width: safe.width * bounds.width,
                height: safe.height * bounds.height
            ).integral.intersection(bounds)
        }
        guard let aspect = mode.aspectRatio else { return bounds }
        let sourceAspect = bounds.width / bounds.height
        if sourceAspect > aspect {
            let width = bounds.height * aspect
            return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        }
        let height = bounds.width / aspect
        return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    private static func makePixelBuffer(
        image: CGImage,
        cropMode: EditorCropMode,
        customCrop: CGRect?,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        guard let buffer,
              let cropped = image.cropping(to: cropRect(for: image, mode: cropMode, customCrop: customCrop))
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func editorError(_ message: String) -> NSError {
        NSError(domain: "GifCapture.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private final class WriterFinishBox: @unchecked Sendable {
        private let lock = NSLock()
        private let writer: AVAssetWriter
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancellationRequested = false

        init(writer: AVAssetWriter) { self.writer = writer }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            let shouldCancel = lock.withLock { () -> Bool in
                if cancellationRequested { return true }
                self.continuation = continuation
                return false
            }
            if shouldCancel {
                writer.cancelWriting()
                continuation.resume(throwing: CancellationError())
                return
            }
            writer.finishWriting { [self] in
                if writer.status == .completed {
                    complete(.success(()))
                } else {
                    complete(.failure(writer.error ?? editorError("Couldn't finish the edited video.")))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { [self] in
                guard takeContinuation() != nil else { return }
                writer.cancelWriting()
                continuation.resume(throwing: editorError("Timed out while finishing the edited video."))
            }
        }

        func cancel() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancellationRequested = true
                defer { self.continuation = nil }
                return self.continuation
            }
            guard let continuation else { return }
            writer.cancelWriting()
            continuation.resume(throwing: CancellationError())
        }

        private func complete(_ result: Result<Void, Error>) {
            guard let continuation = takeContinuation() else { return }
            continuation.resume(with: result)
        }

        private func takeContinuation() -> CheckedContinuation<Void, Error>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }
}
