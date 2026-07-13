import AVFoundation
import ImageIO

/// Converts an existing GIF back into an H.264 .mov (preserving per-frame
/// timing) so it can go through the trim window and re-encode pipeline.
enum GifImporter {
    static func makeVideo(from gifURL: URL) throws -> (url: URL, pixelWidth: Int) {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw NSError(domain: "GifCapture", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read the GIF."])
        }

        let frameCount = CGImageSourceGetCount(source)
        let width = max(2, firstFrame.width & ~1)  // H.264 requires even dimensions
        let height = max(2, firstFrame.height & ~1)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw importError("Couldn't configure the GIF importer.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? importError("Couldn't start converting the GIF.")
        }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for index in 0..<frameCount {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let readyDeadline = Date().addingTimeInterval(60)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status != .failed && writer.status != .cancelled else {
                    throw writer.error ?? importError("The GIF importer stopped unexpectedly.")
                }
                guard Date() < readyDeadline else {
                    writer.cancelWriting()
                    throw importError("Timed out waiting to write GIF frame \(index).")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let buffer = pixelBuffer(from: frame, width: width, height: height, pool: adaptor.pixelBufferPool) {
                guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
                    throw writer.error ?? importError("Couldn't write GIF frame \(index).")
                }
            }
            time += frameDelay(source: source, index: index)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            writer.cancelWriting()
            throw importError("Timed out while finishing the imported GIF.")
        }

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "GifCapture", code: 21,
                                          userInfo: [NSLocalizedDescriptionKey: "Couldn't convert the GIF to video."])
        }
        return (outputURL, width)
    }

    private static func importError(_ message: String) -> NSError {
        NSError(domain: "GifCapture.Importer", code: 20,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
