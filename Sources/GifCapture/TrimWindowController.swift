import AppKit
import AVFoundation
import AVKit

enum TrimResult {
    case saved(URL)
    case cancelled
    case failed(Error)
}

final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let videoURL: URL
    private let pointWidth: Int
    private let completion: (TrimResult) -> Void

    private let asset: AVAsset
    private let player: AVPlayer
    private var duration: Double = 0
    private var timeObserver: Any?
    private var finished = false

    private let slider = TrimRangeSlider()
    private let rangeLabel = NSTextField(labelWithString: " ")
    private let busyLabel = NSTextField(labelWithString: "Converting…")
    private let spinner = NSProgressIndicator()
    private var saveButton: NSButton!
    private var cancelButton: NSButton!

    init(videoURL: URL, pointWidth: Int, completion: @escaping (TrimResult) -> Void) {
        self.videoURL = videoURL
        self.pointWidth = pointWidth
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
                await MainActor.run { self.configure(duration: cmDuration.seconds) }
            } catch {
                await MainActor.run { self.finish(.failed(error)) }
            }
        }
    }

    private func configure(duration: Double) {
        self.duration = duration
        slider.configure(duration: duration)
        updateRangeLabel()
        saveButton.isEnabled = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.slider.playhead = seconds
            // Loop playback within the selected range, QuickTime-style.
            if self.player.rate > 0, seconds >= self.slider.endTime {
                self.player.seek(
                    to: CMTime(seconds: self.slider.startTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
        }
    }

    private func buildUI() {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.onChange = { [weak self] activeTime in
            guard let self else { return }
            self.player.pause()
            self.player.seek(
                to: CMTime(seconds: activeTime, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            self.updateRangeLabel()
        }

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

        let stack = NSStackView(views: [playerView, slider, rangeLabel, buttonRow])
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

    private static func format(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        setBusy(true)
        player.pause()
        let start = slider.startTime
        let end = slider.endTime

        Task {
            do {
                let trimmedURL = try await Self.exportTrimmed(
                    asset: asset, originalURL: videoURL,
                    start: start, end: end, fullDuration: duration
                )
                let width = pointWidth
                let gifURL = try await Task.detached {
                    try GifConverter.convert(videoURL: trimmedURL, pointWidth: width)
                }.value
                await MainActor.run { self.finish(.saved(gifURL)) }
            } catch {
                await MainActor.run { self.finish(.failed(error)) }
            }
        }
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
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func setBusy(_ busy: Bool) {
        saveButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        slider.isEnabled = !busy
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
    private enum DragTarget { case start, end, none }
    private var dragTarget: DragTarget = .none

    private let handleWidth: CGFloat = 10
    private let minimumRange = 0.1

    func configure(duration: Double) {
        self.duration = max(duration, 0.01)
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
        return min(max(t, 0), duration)
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
