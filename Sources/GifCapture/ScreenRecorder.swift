import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isRecording = false

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL!

    func start(rect: CGRect, display: SCDisplay, excludingWindowIDs: [CGWindowID] = []) async throws {
        let scale = matchingScreen(for: display)?.backingScaleFactor ?? 2
        let pixelWidth = max(2, Int((rect.width * scale).rounded()))
        let pixelHeight = max(2, Int((rect.height * scale).rounded()))

        let content = try await SCShareableContent.current
        let excludedWindows = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = false

        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)

        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
        sessionStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "gifcapture.stream.output"))
        self.stream = stream
        try await stream.startCapture()
        isRecording = true
    }

    func stop() async throws -> URL {
        guard let stream else {
            throw NSError(domain: "GifCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }
        isRecording = false
        try? await stream.stopCapture()
        self.stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            videoInput?.markAsFinished()
            assetWriter?.finishWriting { [weak self] in
                guard let self else { return }
                if let error = self.assetWriter?.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: self.outputURL)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isRecording, sampleBuffer.isValid else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let writer = assetWriter, let input = videoInput, let adaptor = pixelBufferAdaptor else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        adaptor.append(imageBuffer, withPresentationTime: pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
    }

    private func matchingScreen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == display.displayID
        }
    }
}
