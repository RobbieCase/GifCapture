import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isRecording = false

    /// Toggled from the main thread while recording; read per-frame on the capture queue.
    var zoomActive = false
    private var currentZoom: CGFloat = 1.0
    private var captureRect: CGRect = .zero      // top-left origin, points, display-relative
    private var displayBounds: CGRect = .zero    // CG global coords (top-left origin)
    private var scaleFactor: CGFloat = 2
    private lazy var ciContext = CIContext()

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL!

    func start(
        rect: CGRect,
        display: SCDisplay,
        excludingWindowIDs: [CGWindowID] = [],
        showsCursor: Bool = true
    ) async throws {
        let scale = matchingScreen(for: display)?.backingScaleFactor ?? 2
        let pixelWidth = max(2, Int((rect.width * scale).rounded()))
        let pixelHeight = max(2, Int((rect.height * scale).rounded()))

        captureRect = rect
        displayBounds = CGDisplayBounds(display.displayID)
        scaleFactor = scale
        currentZoom = 1.0
        zoomActive = false

        let content = try await SCShareableContent.current
        let excludedWindows = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = showsCursor
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
        adaptor.append(processedBuffer(from: imageBuffer), withPresentationTime: pts)
    }

    /// Applies the animated cursor-tracked zoom, rendering into a fresh buffer
    /// from the adaptor's pool. Returns the source buffer untouched at 1x.
    private func processedBuffer(from source: CVImageBuffer) -> CVImageBuffer {
        let target: CGFloat = zoomActive ? 2.0 : 1.0
        if abs(currentZoom - target) > 0.004 {
            currentZoom += (target - currentZoom) * 0.16
        } else {
            currentZoom = target
        }
        guard currentZoom > 1.01, let pool = pixelBufferAdaptor?.pixelBufferPool else { return source }

        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))

        // Cursor position in capture-space pixels (top-left origin), via CG global coords.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let cx = (cursor.x - displayBounds.minX - captureRect.minX) * scaleFactor
        let cyTop = (cursor.y - displayBounds.minY - captureRect.minY) * scaleFactor

        let visibleW = width / currentZoom
        let visibleH = height / currentZoom
        let originX = min(max(cx - visibleW / 2, 0), width - visibleW)
        let originYTop = min(max(cyTop - visibleH / 2, 0), height - visibleH)
        let originY = height - originYTop - visibleH // CoreImage is bottom-left origin

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return source }

        let image = CIImage(cvImageBuffer: source)
            .cropped(to: CGRect(x: originX, y: originY, width: visibleW, height: visibleH))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
            .transformed(by: CGAffineTransform(scaleX: currentZoom, y: currentZoom))
        ciContext.render(image, to: output)
        return output
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
