import AppKit
import AVFoundation
import AVKit

enum TrimResult {
    case saved(gif: URL, mp4: URL?)
    case cancelled
    case failed(Error)
}

final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let videoURL: URL
    private let outputWidth: GifOutputWidth
    private let outputGifURL: URL?
    private let completion: (TrimResult) -> Void

    private let asset: AVAsset
    private let player: AVPlayer
    private var duration: Double = 0
    private var frameRate: Double = 30
    private var frameTimes: [Double] = []
    private var timeObserver: Any?
    private var previewTimer: Timer?
    private var previewDirection = 1
    private var finished = false

    private let slider = TrimRangeSlider()
    private let rangeLabel = NSTextField(labelWithString: " ")
    private let busyLabel = NSTextField(labelWithString: "Converting…")
    private let spinner = NSProgressIndicator()
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let frameLabel = NSTextField(labelWithString: "Frame —")
    private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loopPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cropPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resizeField = NSTextField(string: "")
    private let targetSizeCheckbox = NSButton(checkboxWithTitle: "Compress below", target: nil, action: nil)
    private let targetSizeField = NSTextField(string: "5")
    private let cropPreview = CropPreviewView()
    private var saveButton: NSButton!
    private var cancelButton: NSButton!

    init(videoURL: URL, outputWidth: GifOutputWidth, outputGifURL: URL? = nil, completion: @escaping (TrimResult) -> Void) {
        self.videoURL = videoURL
        self.outputWidth = outputWidth
        self.outputGifURL = outputGifURL
        self.completion = completion
        self.asset = AVURLAsset(url: videoURL)
        self.player = AVPlayer(url: videoURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim Recording"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        Task {
            do {
                let cmDuration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let loadedFrameRate = try await tracks.first?.load(.nominalFrameRate) ?? 30
                let timeline = try await VideoEditorExporter.frameTimeline(asset: asset)
                await MainActor.run {
                    self.configure(
                        duration: cmDuration.seconds,
                        frameRate: Double(loadedFrameRate),
                        frameTimes: timeline
                    )
                }
            } catch {
                await MainActor.run { self.finish(.failed(error)) }
            }
        }
    }

    private func configure(duration: Double, frameRate: Double, frameTimes: [Double]) {
        self.duration = duration
        self.frameTimes = frameTimes
        if frameTimes.count > 1 {
            let intervals = zip(frameTimes.dropFirst(), frameTimes)
                .map { $0.0 - $0.1 }.filter { $0 > 0 }.sorted()
            self.frameRate = intervals.isEmpty ? max(1, frameRate) : 1 / intervals[intervals.count / 2]
        } else {
            self.frameRate = max(1, frameRate)
        }
        slider.configure(duration: duration, frameTimes: frameTimes, fallbackFrameDuration: 1 / self.frameRate)
        updateRangeLabel()
        updateFrameLabel(time: 0)
        saveButton.isEnabled = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1 / self.frameRate, preferredTimescale: 60_000),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.slider.playhead = seconds
            self.updateFrameLabel(time: seconds)
            // Loop playback within the selected range, QuickTime-style.
            if self.player.rate > 0, seconds >= self.slider.endTime {
                self.player.seek(
                    to: CMTime(seconds: self.slider.startTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
                self.player.playImmediately(atRate: Float(self.selectedSpeed))
            }
        }
    }

    private func buildUI() {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.translatesAutoresizingMaskIntoConstraints = false
        cropPreview.translatesAutoresizingMaskIntoConstraints = false
        cropPreview.isHidden = true
        playerView.addSubview(cropPreview)
        NSLayoutConstraint.activate([
            cropPreview.topAnchor.constraint(equalTo: playerView.topAnchor),
            cropPreview.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            cropPreview.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            cropPreview.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
        ])

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.onChange = { [weak self] activeTime in
            guard let self else { return }
            self.player.pause()
            self.player.seek(
                to: CMTime(seconds: activeTime, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            self.updateRangeLabel()
            self.updateFrameLabel(time: activeTime)
        }

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        let previousFrame = NSButton(title: "◀︎ Frame", target: self, action: #selector(stepBackward))
        let nextFrame = NSButton(title: "Frame ▶︎", target: self, action: #selector(stepForward))
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor
        let transport = NSStackView(views: [playButton, previousFrame, nextFrame, frameLabel, NSView()])
        transport.orientation = .horizontal
        transport.spacing = 8

        speedPopup.addItems(withTitles: ["0.5×", "0.75×", "1×", "1.5×", "2×"])
        speedPopup.selectItem(at: 2)
        loopPopup.addItems(withTitles: EditorLoopMode.allCases.map(\.rawValue))
        cropPopup.addItems(withTitles: EditorCropMode.allCases.map(\.rawValue))
        cropPopup.target = self
        cropPopup.action = #selector(cropChanged)
        resizeField.placeholderString = "Original"
        resizeField.alignment = .right
        resizeField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        targetSizeField.alignment = .right
        targetSizeField.widthAnchor.constraint(equalToConstant: 42).isActive = true
        targetSizeField.isEnabled = false
        targetSizeCheckbox.target = self
        targetSizeCheckbox.action = #selector(targetSizeToggled)
        let editRow = NSStackView(views: [
            NSTextField(labelWithString: "Crop:"), cropPopup,
            NSTextField(labelWithString: "Width:"), resizeField,
            NSTextField(labelWithString: "Speed:"), speedPopup,
            NSTextField(labelWithString: "Loop:"), loopPopup,
        ])
        editRow.orientation = .horizontal
        editRow.spacing = 7
        let targetRow = NSStackView(views: [targetSizeCheckbox, targetSizeField, NSTextField(labelWithString: "MB"), NSView()])
        targetRow.orientation = .horizontal
        targetRow.spacing = 6

        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        busyLabel.font = .systemFont(ofSize: 12)
        busyLabel.textColor = .secondaryLabelColor
        busyLabel.isHidden = true

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        saveButton = NSButton(title: "Save GIF", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false // until duration loads

        let buttonRow = NSStackView(views: [spinner, busyLabel, NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [playerView, transport, slider, rangeLabel, editRow, targetRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerView.widthAnchor.constraint(equalToConstant: 632),
            playerView.heightAnchor.constraint(equalToConstant: 355),
            transport.widthAnchor.constraint(equalTo: playerView.widthAnchor),
            slider.widthAnchor.constraint(equalTo: playerView.widthAnchor),
            slider.heightAnchor.constraint(equalToConstant: 30),
            buttonRow.widthAnchor.constraint(equalTo: playerView.widthAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    private func updateRangeLabel() {
        let length = slider.endTime - slider.startTime
        rangeLabel.stringValue =
            "\(Self.format(slider.startTime)) – \(Self.format(slider.endTime))   ·   \(Self.format(length)) selected"
    }

    private func updateFrameLabel(time: Double) {
        let frame = nearestFrameIndex(to: time)
        frameLabel.stringValue = "Frame \(frame)  ·  \(Self.format(time))"
    }

    private func nearestFrameIndex(to time: Double) -> Int {
        guard !frameTimes.isEmpty else { return max(0, Int((time * frameRate).rounded())) }
        return frameTimes.indices.min { abs(frameTimes[$0] - time) < abs(frameTimes[$1] - time) } ?? 0
    }

    private var selectedSpeed: Double {
        [0.5, 0.75, 1, 1.5, 2][max(0, speedPopup.indexOfSelectedItem)]
    }

    private var selectedLoopMode: EditorLoopMode {
        EditorLoopMode.allCases[max(0, loopPopup.indexOfSelectedItem)]
    }

    private var selectedCropMode: EditorCropMode {
        EditorCropMode.allCases[max(0, cropPopup.indexOfSelectedItem)]
    }

    private static func format(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Actions

    @objc private func togglePlayback() {
        if player.rate != 0 || previewTimer != nil {
            pausePlayback()
            return
        }
        if player.currentTime().seconds < slider.startTime || player.currentTime().seconds >= slider.endTime {
            seek(to: selectedLoopMode == .reverse ? slider.endTime : slider.startTime)
        }
        switch selectedLoopMode {
        case .forward:
            player.playImmediately(atRate: Float(selectedSpeed))
        case .reverse:
            startManualPlayback(direction: -1)
        case .pingPong:
            startManualPlayback(direction: 1)
        }
        playButton.title = "Pause"
    }

    @objc private func stepBackward() { step(by: -1) }
    @objc private func stepForward() { step(by: 1) }

    private func step(by frames: Int) {
        pausePlayback()
        if !frameTimes.isEmpty {
            let index = min(max(nearestFrameIndex(to: player.currentTime().seconds) + frames, 0), frameTimes.count - 1)
            seek(to: frameTimes[index])
        } else {
            seek(to: player.currentTime().seconds + Double(frames) / frameRate)
        }
    }

    private func seek(to time: Double) {
        let snapped = (time * frameRate).rounded() / frameRate
        let clamped = min(max(snapped, slider.startTime), slider.endTime)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 60_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        slider.playhead = clamped
        updateFrameLabel(time: clamped)
    }

    private func startManualPlayback(direction: Int) {
        previewDirection = direction
        let timer = Timer(timeInterval: max(1 / 120, 1 / frameRate / selectedSpeed), repeats: true) { [weak self] _ in
            guard let self else { return }
            var next = self.player.currentTime().seconds + Double(self.previewDirection) / self.frameRate
            if next >= self.slider.endTime || next <= self.slider.startTime {
                if self.selectedLoopMode == .pingPong {
                    self.previewDirection *= -1
                    next = min(max(next, self.slider.startTime), self.slider.endTime)
                } else {
                    next = self.previewDirection > 0 ? self.slider.startTime : self.slider.endTime
                }
            }
            self.seek(to: next)
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func pausePlayback() {
        player.pause()
        previewTimer?.invalidate()
        previewTimer = nil
        playButton.title = "Play"
    }

    @objc private func targetSizeToggled() {
        targetSizeField.isEnabled = targetSizeCheckbox.state == .on
    }

    @objc private func cropChanged() {
        cropPreview.cropMode = selectedCropMode
        cropPreview.isHidden = selectedCropMode == .none
    }

    @objc private func saveTapped() {
        setBusy(true)
        player.pause()
        let start = slider.startTime
        let end = slider.endTime
        let requestedWidth = Int(resizeField.stringValue).flatMap { $0 >= 2 ? $0 : nil }
        let targetBytes: Int? = {
            guard targetSizeCheckbox.state == .on,
                  let megabytes = Double(targetSizeField.stringValue), megabytes > 0 else { return nil }
            return Int(megabytes * 1_000_000)
        }()
        let options = VideoEditOptions(
            startTime: start,
            endTime: end,
            frameRate: frameRate,
            cropMode: selectedCropMode,
            outputWidth: requestedWidth,
            speed: selectedSpeed,
            loopMode: selectedLoopMode,
            frameTimes: frameTimes
        )

        Task {
            do {
                let trimmedURL: URL
                if options.needsFrameExport {
                    trimmedURL = try await Task.detached {
                        try VideoEditorExporter.export(asset: AVURLAsset(url: self.videoURL), options: options)
                    }.value
                    try? FileManager.default.removeItem(at: videoURL)
                } else {
                    trimmedURL = try await Self.exportTrimmed(
                        asset: asset, originalURL: videoURL,
                        start: start, end: end, fullDuration: duration
                    )
                }
                let width = requestedWidth.map(GifOutputWidth.pixels) ?? outputWidth
                let gifDestination = outputGifURL ?? GifConverter.makeDefaultOutputURL()

                // MP4 copy first: GifConverter deletes the source video when done.
                var mp4URL: URL?
                if AppSettings.load().exportMP4 {
                    let target = gifDestination.deletingPathExtension().appendingPathExtension("mp4")
                    mp4URL = try await Self.exportMP4(from: trimmedURL, to: target)
                }

                let gifURL = try await Task.detached {
                    try GifConverter.convert(
                        videoURL: trimmedURL,
                        outputWidth: width,
                        outputURL: gifDestination,
                        targetBytes: targetBytes
                    )
                }.value
                await MainActor.run { self.finish(.saved(gif: gifURL, mp4: mp4URL)) }
            } catch {
                await MainActor.run { self.finish(.failed(error)) }
            }
        }
    }

    /// Remuxes the (already H.264) recording into an .mp4 container — fast, no
    /// re-encode. MP4s are often 10x smaller than the GIF and autoplay in chat apps.
    private static func exportMP4(from videoURL: URL, to destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "GifCapture", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create MP4 export session"])
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .mp4
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ?? NSError(
                        domain: "GifCapture", code: 31,
                        userInfo: [NSLocalizedDescriptionKey: "MP4 export failed"]))
                }
            }
        }
        return destination
    }

    @objc private func cancelTapped() {
        finish(.cancelled)
    }

    func windowWillClose(_ notification: Notification) {
        // Red close button — treat as cancel unless we already finished.
        guard !finished else { return }
        finished = true
        teardown()
        try? FileManager.default.removeItem(at: videoURL)
        completion(.cancelled)
    }

    private func finish(_ result: TrimResult) {
        guard !finished else { return }
        finished = true
        teardown()
        if case .cancelled = result {
            try? FileManager.default.removeItem(at: videoURL)
        }
        close()
        completion(result)
    }

    private func teardown() {
        pausePlayback()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func setBusy(_ busy: Bool) {
        saveButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        slider.isEnabled = !busy
        [playButton, speedPopup, loopPopup, cropPopup, resizeField, targetSizeCheckbox]
            .forEach { $0.isEnabled = !busy }
        targetSizeField.isEnabled = !busy && targetSizeCheckbox.state == .on
        spinner.isHidden = !busy
        busyLabel.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: - Trim export

    /// Re-exports the selected range to a new file. Returns the original untouched
    /// when the selection is (effectively) the whole clip.
    private static func exportTrimmed(
        asset: AVAsset, originalURL: URL,
        start: Double, end: Double, fullDuration: Double
    ) async throws -> URL {
        if start <= 0.05, end >= fullDuration - 0.05 {
            return originalURL
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "GifCapture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create trim export session"])
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ?? NSError(
                        domain: "GifCapture", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Trim export failed"]))
                }
            }
        }
        try? FileManager.default.removeItem(at: originalURL)
        return outputURL
    }
}

// MARK: - Trim range slider

final class TrimRangeSlider: NSView {
    private(set) var startTime: Double = 0
    private(set) var endTime: Double = 1
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var isEnabled = true
    /// Called continuously while dragging, with the time of the handle being moved.
    var onChange: ((Double) -> Void)?

    private var duration: Double = 1
    private var frameDuration: Double = 1 / 30
    private var snapTimes: [Double] = []
    private enum DragTarget { case start, end, none }
    private var dragTarget: DragTarget = .none

    private let handleWidth: CGFloat = 10
    private var minimumRange: Double { max(frameDuration, 0.01) }

    func configure(duration: Double, frameTimes: [Double], fallbackFrameDuration: Double) {
        self.duration = max(duration, 0.01)
        let intervals = zip(frameTimes.dropFirst(), frameTimes).map { $0.0 - $0.1 }.filter { $0 > 0 }
        self.frameDuration = max(1 / 240, intervals.min() ?? fallbackFrameDuration)
        snapTimes = frameTimes + [self.duration]
        startTime = 0
        endTime = self.duration
        needsDisplay = true
    }

    private var trackRect: NSRect { bounds.insetBy(dx: handleWidth + 2, dy: 5) }

    private func x(for time: Double) -> CGFloat {
        trackRect.minX + trackRect.width * CGFloat(time / duration)
    }

    private func time(for x: CGFloat) -> Double {
        let t = Double((x - trackRect.minX) / trackRect.width) * duration
        let snapped = snapTimes.min(by: { abs($0 - t) < abs($1 - t) })
            ?? ((t / frameDuration).rounded() * frameDuration)
        return min(max(snapped, 0), duration)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Track
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.35).setFill()
        track.fill()

        let startX = x(for: startTime)
        let endX = x(for: endTime)
        let selection = NSRect(x: startX, y: trackRect.minY, width: endX - startX, height: trackRect.height)

        // Selected range — QuickTime-style yellow frame
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        selection.fill()
        NSColor.systemYellow.setStroke()
        let frame = NSBezierPath(rect: selection)
        frame.lineWidth = 3
        frame.stroke()

        // Handles
        for handleX in [startX, endX] {
            let handleRect = NSRect(
                x: handleX - handleWidth / 2,
                y: bounds.minY + 1,
                width: handleWidth,
                height: bounds.height - 2
            )
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3).fill()
        }

        // Playhead
        if playhead > startTime, playhead < endTime {
            let px = x(for: playhead)
            NSColor.white.setFill()
            NSRect(x: px - 1, y: trackRect.minY, width: 2, height: trackRect.height).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let startX = x(for: startTime)
        let endX = x(for: endTime)
        let grab: CGFloat = 14
        // Closest handle wins when they overlap.
        if abs(point.x - startX) <= grab || abs(point.x - endX) <= grab {
            dragTarget = abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
        } else {
            dragTarget = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, dragTarget != .none else { return }
        let point = convert(event.locationInWindow, from: nil)
        let t = time(for: point.x)
        switch dragTarget {
        case .start:
            startTime = min(t, endTime - minimumRange)
            startTime = max(0, startTime)
            onChange?(startTime)
        case .end:
            endTime = max(t, startTime + minimumRange)
            endTime = min(duration, endTime)
            onChange?(endTime)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = .none
    }

    override func resetCursorRects() {
        for handleX in [x(for: startTime), x(for: endTime)] {
            let rect = NSRect(x: handleX - 10, y: 0, width: 20, height: bounds.height)
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }
}

/// Non-interactive preview of the centered crop that will be exported.
final class CropPreviewView: NSView {
    var cropMode: EditorCropMode = .none { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let aspect = cropMode.aspectRatio else { return }
        let crop: NSRect
        if bounds.width / bounds.height > aspect {
            let width = bounds.height * aspect
            crop = NSRect(x: bounds.midX - width / 2, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / aspect
            crop = NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(crop)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.58).setFill()
        shade.fill()
        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: crop.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}
