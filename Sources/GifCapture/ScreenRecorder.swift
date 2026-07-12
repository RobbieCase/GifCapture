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
    private var followsWindow = false
    private var outputPixelSize: CGSize = .zero
    private let followRectLock = NSLock()
    private struct TimedCaptureRect {
        let hostTime: UInt64
        let rect: CGRect
    }
    private var followedCaptureRects: [TimedCaptureRect] = []
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
        showsCursor: Bool = true,
        followsWindow: Bool = false
    ) async throws {
        let scale = matchingScreen(for: display)?.backingScaleFactor ?? 2
        let pixelWidth = max(2, Int((rect.width * scale).rounded()))
        let pixelHeight = max(2, Int((rect.height * scale).rounded()))

        captureRect = rect
        displayBounds = CGDisplayBounds(display.displayID)
        scaleFactor = scale
        self.followsWindow = followsWindow
        outputPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        followRectLock.withLock {
            followedCaptureRects = [TimedCaptureRect(hostTime: mach_absolute_time(), rect: rect)]
        }
        currentZoom = 1.0
        zoomActive = false

        let content = try await SCShareableContent.current
        let excludedWindows = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        if followsWindow {
            // Capture the display once and crop each frame to the moving window.
            // Reconfiguring SCStream for every position change visibly steps.
            config.sourceRect = CGRect(origin: .zero, size: displayBounds.size)
            config.width = max(2, Int((displayBounds.width * scale).rounded()))
            config.height = max(2, Int((displayBounds.height * scale).rounded()))
            config.queueDepth = 5
        } else {
            config.sourceRect = rect
            config.width = pixelWidth
            config.height = pixelHeight
        }
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
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight
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

    /// Updates the crop used by follow-window mode. This is deliberately local
    /// and synchronous so tracking never waits for ScreenCaptureKit to reconfigure.
    func setFollowCaptureRect(_ rect: CGRect) {
        followRectLock.withLock {
            followedCaptureRects.append(TimedCaptureRect(hostTime: mach_absolute_time(), rect: rect))
            if followedCaptureRects.count > 180 {
                followedCaptureRects.removeFirst(followedCaptureRects.count - 180)
            }
        }
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
        adaptor.append(
            processedBuffer(from: imageBuffer, displayTime: frameDisplayTime(sampleBuffer)),
            withPresentationTime: pts
        )
    }

    /// Crops a followed window and applies animated cursor-tracked zoom. Normal
    /// fixed captures still return the source buffer untouched at 1x.
    private func processedBuffer(from source: CVImageBuffer, displayTime: UInt64?) -> CVImageBuffer {
        let target: CGFloat = zoomActive ? 2.0 : 1.0
        if abs(currentZoom - target) > 0.004 {
            currentZoom += (target - currentZoom) * 0.16
        } else {
            currentZoom = target
        }
        guard (followsWindow || currentZoom > 1.01),
              let pool = pixelBufferAdaptor?.pixelBufferPool else { return source }

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        let baseRect: CGRect
        if followsWindow {
            let rect = followRect(at: displayTime)
            baseRect = CGRect(
                x: rect.minX * scaleFactor,
                y: rect.minY * scaleFactor,
                width: rect.width * scaleFactor,
                height: rect.height * scaleFactor
            )
        } else {
            baseRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        }

        // Cursor position in capture-space pixels (top-left origin), via CG global coords.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let cx: CGFloat
        let cyTop: CGFloat
        if followsWindow {
            cx = (cursor.x - displayBounds.minX) * scaleFactor
            cyTop = (cursor.y - displayBounds.minY) * scaleFactor
        } else {
            cx = (cursor.x - displayBounds.minX - captureRect.minX) * scaleFactor
            cyTop = (cursor.y - displayBounds.minY - captureRect.minY) * scaleFactor
        }

        let visibleW = baseRect.width / currentZoom
        let visibleH = baseRect.height / currentZoom
        let originX = min(max(cx - visibleW / 2, baseRect.minX), baseRect.maxX - visibleW)
        let originYTop = min(max(cyTop - visibleH / 2, baseRect.minY), baseRect.maxY - visibleH)
        let originY = sourceHeight - originYTop - visibleH // CoreImage is bottom-left origin

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return source }

        let image = CIImage(cvImageBuffer: source)
            .cropped(to: CGRect(x: originX, y: originY, width: visibleW, height: visibleH))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
            .transformed(by: CGAffineTransform(
                scaleX: outputPixelSize.width / visibleW,
                y: outputPixelSize.height / visibleH
            ))
        ciContext.render(image, to: output)
        return output
    }

    /// ScreenCaptureKit delivers frames after the compositor has produced them.
    /// Pairing a frame with the newest tracking value makes the crop lead the
    /// pixels and creates visible shake. Match against the frame's host timestamp.
    private func followRect(at displayTime: UInt64?) -> CGRect {
        followRectLock.withLock {
            guard let latest = followedCaptureRects.last else { return captureRect }
            guard let displayTime else { return latest.rect }
            return followedCaptureRects.min { lhs, rhs in
                hostTimeDistance(lhs.hostTime, displayTime) < hostTimeDistance(rhs.hostTime, displayTime)
            }?.rect ?? latest.rect
        }
    }

    private func hostTimeDistance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private func frameDisplayTime(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let value = attachments.first?[.displayTime] else { return nil }
        if let number = value as? NSNumber { return number.uint64Value }
        return value as? UInt64
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
