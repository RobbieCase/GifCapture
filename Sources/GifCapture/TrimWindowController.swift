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
    private var previewFrameIndex = 0
    private var manualSeekInFlight = false
    private var finished = false
    private var exportTask: Task<Void, Never>?

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
                let presentationSize: CGSize
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    presentationSize = CGRect(origin: .zero, size: naturalSize)
                        .applying(transform).standardized.size
                } else {
                    presentationSize = .zero
                }
                let timeline = try await VideoEditorExporter.frameTimeline(asset: asset)
                await MainActor.run {
                    self.configure(
                        duration: cmDuration.seconds,
                        frameRate: Double(loadedFrameRate),
                        frameTimes: timeline,
                        presentationSize: presentationSize
                    )
                }
            } catch {
                await MainActor.run { self.finish(.failed(error)) }
            }
        }
    }

    private func configure(
        duration: Double,
        frameRate: Double,
        frameTimes: [Double],
        presentationSize: CGSize
    ) {
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
        cropPreview.sourceSize = presentationSize
        updateRangeLabel()
        updateFrameLabel(time: 0)
        saveButton.isEnabled = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1 / self.frameRate, preferredTimescale: 60_000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handlePlaybackTick(time.seconds) }
        }
    }

    private func handlePlaybackTick(_ seconds: Double) {
        slider.playhead = seconds
        updateFrameLabel(time: seconds)
        // Loop and direction changes stay inside the selected range.
        if player.rate > 0, seconds >= slider.endTime - 0.001 {
            if selectedLoopMode == .pingPong {
                startPlayback(direction: -1)
            } else {
                seek(to: slider.startTime) { [weak self] in self?.startPlayback(direction: 1) }
            }
        } else if player.rate < 0, seconds <= slider.startTime + 0.001 {
            if selectedLoopMode == .pingPong {
                startPlayback(direction: 1)
            } else {
                seek(to: slider.endTime) { [weak self] in self?.startPlayback(direction: -1) }
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
            self.pausePlayback()
            self.player.seek(
                to: CMTime(seconds: activeTime, preferredTimescale: 60_000),
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
        speedPopup.target = self
        speedPopup.action = #selector(playbackSettingChanged)
        loopPopup.addItems(withTitles: EditorLoopMode.allCases.map(\.rawValue))
        loopPopup.target = self
        loopPopup.action = #selector(playbackSettingChanged)
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
        let direction = selectedLoopMode == .reverse ? -1 : 1
        let current = player.currentTime().seconds
        let needsReposition = (direction < 0 && current <= slider.startTime + 0.001)
            || current < slider.startTime || current >= slider.endTime
        if needsReposition {
            let destination = direction < 0 ? slider.endTime : slider.startTime
            seek(to: destination) { [weak self] in self?.startPlayback(direction: direction) }
        } else {
            startPlayback(direction: direction)
        }
    }

    @objc private func stepBackward() { step(by: -1) }
    @objc private func stepForward() { step(by: 1) }

    private func step(by frames: Int) {
        pausePlayback()
        let target: Double
        if !frameTimes.isEmpty {
            let index = min(max(nearestFrameIndex(to: player.currentTime().seconds) + frames, 0), frameTimes.count - 1)
            target = frameTimes[index]
        } else {
            target = player.currentTime().seconds + Double(frames) / frameRate
        }
        guard target >= slider.startTime, target <= slider.endTime else { return }
        player.currentItem?.step(byCount: frames)
        // AVPlayer updates currentTime asynchronously after native frame steps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            let actual = self.player.currentTime().seconds
            if !actual.isFinite || abs(actual - target) > max(0.02, 1.5 / self.frameRate) {
                self.seek(to: target)
            } else {
                self.slider.playhead = actual
                self.updateFrameLabel(time: actual)
            }
        }
    }

    private func seek(
        to time: Double,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let snapped = frameTimes.min(by: { abs($0 - time) < abs($1 - time) })
            ?? ((time * frameRate).rounded() / frameRate)
        let clamped = min(max(snapped, slider.startTime), slider.endTime)
        player.pause()
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 60_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard finished, let completion else { return }
            Task { @MainActor in completion() }
        }
        slider.playhead = clamped
        updateFrameLabel(time: clamped)
    }

    private func startPlayback(direction: Int) {
        previewTimer?.invalidate()
        previewTimer = nil
        previewDirection = direction
        if direction > 0 {
            player.playImmediately(atRate: Float(selectedSpeed))
        } else {
            player.pause()
            startManualPlayback(direction: -1)
        }
        playButton.title = "Pause"
    }

    private func startManualPlayback(direction: Int) {
        previewDirection = direction
        previewFrameIndex = nearestFrameIndex(to: player.currentTime().seconds)
        manualSeekInFlight = false
        let timer = Timer(timeInterval: max(1 / 120, 1 / frameRate / selectedSpeed), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.manualPlaybackTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func manualPlaybackTick() {
        guard !frameTimes.isEmpty else {
            seek(to: player.currentTime().seconds + Double(previewDirection) / frameRate)
            return
        }
        guard !manualSeekInFlight else { return }
        let firstIndex = frameTimes.firstIndex { $0 >= slider.startTime - 0.000_001 } ?? 0
        let lastIndex = frameTimes.lastIndex { $0 < slider.endTime - 0.000_001 } ?? frameTimes.count - 1
        var nextIndex = previewFrameIndex + previewDirection
        if nextIndex > lastIndex || nextIndex < firstIndex
            || frameTimes[nextIndex] >= slider.endTime
            || frameTimes[nextIndex] < slider.startTime {
            if selectedLoopMode == .pingPong {
                previewDirection *= -1
                nextIndex = previewFrameIndex + previewDirection
            } else {
                nextIndex = previewDirection > 0 ? firstIndex : lastIndex
            }
        }
        guard frameTimes.indices.contains(nextIndex) else { return }
        previewFrameIndex = nextIndex
        manualSeekInFlight = true
        seek(to: frameTimes[nextIndex]) { [weak self] in self?.manualSeekInFlight = false }
    }

    private func pausePlayback() {
        player.pause()
        previewTimer?.invalidate()
        previewTimer = nil
        manualSeekInFlight = false
        playButton.title = "Play"
    }

    @objc private func targetSizeToggled() {
        targetSizeField.isEnabled = targetSizeCheckbox.state == .on
    }

    @objc private func cropChanged() {
        cropPreview.cropMode = selectedCropMode
        cropPreview.isHidden = selectedCropMode == .none
    }

    @objc private func playbackSettingChanged() {
        let wasPlaying = player.rate != 0 || previewTimer != nil
        pausePlayback()
        if wasPlaying { togglePlayback() }
    }

    @objc private func saveTapped() {
        guard exportTask == nil else { return }
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
            frameTimes: frameTimes,
            customCrop: cropPreview.normalizedCustomCrop
        )

        exportTask = Task { [weak self] in
            guard let self else { return }
            var transientVideo: URL?
            var temporaryMP4: URL?
            var committedGIF: URL?
            do {
                let trimmedURL: URL
                if options.needsFrameExport {
                    trimmedURL = try await Self.exportEditedVideo(from: self.videoURL, options: options)
                    transientVideo = trimmedURL
                } else {
                    trimmedURL = try await Self.exportTrimmed(
                        asset: self.asset, originalURL: self.videoURL,
                        start: start, end: end, fullDuration: self.duration
                    )
                    if trimmedURL != self.videoURL { transientVideo = trimmedURL }
                }
                try Task.checkCancellation()
                let width = requestedWidth.map(GifOutputWidth.pixels) ?? self.outputWidth
                let gifDestination = self.outputGifURL ?? GifConverter.makeDefaultOutputURL()

                var finalMP4: URL?
                if AppSettings.load().exportMP4 {
                    let target = gifDestination.deletingPathExtension().appendingPathExtension("mp4")
                    guard !FileManager.default.fileExists(atPath: target.path) else {
                        throw GifConverterError.outputAlreadyExists(target.lastPathComponent)
                    }
                    let temporary = target.deletingLastPathComponent()
                        .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial")
                        .appendingPathExtension("mp4")
                    temporaryMP4 = temporary
                    _ = try await Self.exportMP4(from: trimmedURL, to: temporary)
                    finalMP4 = target
                }

                let gifURL = try await GifConverter.convert(
                    videoURL: trimmedURL,
                    outputWidth: width,
                    outputURL: gifDestination,
                    targetBytes: targetBytes
                )
                committedGIF = gifURL
                try Task.checkCancellation()

                if let temporaryMP4, let finalMP4 {
                    do {
                        try FileManager.default.moveItem(at: temporaryMP4, to: finalMP4)
                    } catch {
                        try? FileManager.default.removeItem(at: gifURL)
                        committedGIF = nil
                        throw error
                    }
                }
                try? FileManager.default.removeItem(at: self.videoURL)
                if let transientVideo { try? FileManager.default.removeItem(at: transientVideo) }
                self.exportTask = nil
                self.finish(.saved(gif: gifURL, mp4: finalMP4))
            } catch is CancellationError {
                if let committedGIF { try? FileManager.default.removeItem(at: committedGIF) }
                if let temporaryMP4 { try? FileManager.default.removeItem(at: temporaryMP4) }
                if let transientVideo { try? FileManager.default.removeItem(at: transientVideo) }
                self.exportTask = nil
                self.setBusy(false)
            } catch {
                if let committedGIF { try? FileManager.default.removeItem(at: committedGIF) }
                if let temporaryMP4 { try? FileManager.default.removeItem(at: temporaryMP4) }
                if let transientVideo { try? FileManager.default.removeItem(at: transientVideo) }
                self.exportTask = nil
                self.setBusy(false)
                self.showExportError(error)
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
        try await performExport(
            session, to: destination, as: .mp4,
            fallbackError: NSError(domain: "GifCapture", code: 31,
                                   userInfo: [NSLocalizedDescriptionKey: "MP4 export failed"])
        )
        return destination
    }

    @objc private func cancelTapped() {
        if let exportTask {
            busyLabel.stringValue = "Cancelling…"
            exportTask.cancel()
            return
        }
        finish(.cancelled)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let exportTask else { return true }
        busyLabel.stringValue = "Cancelling…"
        exportTask.cancel()
        return false
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
        cancelButton.isEnabled = true
        cancelButton.title = busy ? "Cancel Export" : "Cancel"
        slider.isEnabled = !busy
        [playButton, speedPopup, loopPopup, cropPopup, resizeField, targetSizeCheckbox]
            .forEach { $0.isEnabled = !busy }
        targetSizeField.isEnabled = !busy && targetSizeCheckbox.state == .on
        spinner.isHidden = !busy
        busyLabel.isHidden = !busy
        if busy {
            busyLabel.stringValue = "Converting…"
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't create GIF"
        alert.informativeText = error.localizedDescription
            + "\n\nThe recording is still open, so you can change the settings and retry."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func exportEditedVideo(from source: URL, options: VideoEditOptions) async throws -> URL {
        let task = Task.detached {
            try await VideoEditorExporter.export(asset: AVURLAsset(url: source), options: options)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await performExport(
            session, to: outputURL, as: .mov,
            fallbackError: NSError(domain: "GifCapture", code: 4,
                                   userInfo: [NSLocalizedDescriptionKey: "Trim export failed"])
        )
        return outputURL
    }

    private static func performExport(
        _ session: AVAssetExportSession,
        to destination: URL,
        as fileType: AVFileType,
        fallbackError: Error
    ) async throws {
        if #available(macOS 15.0, *) {
            try await session.export(to: destination, as: fileType)
        } else {
            try await legacyExport(
                ExportSessionBox(session), to: destination,
                as: fileType, fallbackError: fallbackError
            )
        }
    }

    @available(macOS, introduced: 10.7, obsoleted: 15.0)
    private static func legacyExport(
        _ box: ExportSessionBox,
        to destination: URL,
        as fileType: AVFileType,
        fallbackError: Error
    ) async throws {
        box.session.outputURL = destination
        box.session.outputFileType = fileType
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.session.exportAsynchronously {
                    if box.session.status == .completed {
                        continuation.resume()
                    } else if box.session.status == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: box.session.error ?? fallbackError)
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}

// MARK: - Trim range slider

final class TrimRangeSlider: NSView {
    private(set) var startTime: Double = 0
    private(set) var endTime: Double = 1
    var playhead: Double = 0 {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var isEnabled = true
    /// Called continuously while dragging, with the time of the handle being moved.
    var onChange: ((Double) -> Void)?

    private var duration: Double = 1
    private var frameDuration: Double = 1 / 30
    private var snapTimes: [Double] = []
    private enum DragTarget { case start, end, playhead, none }
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
        let px = x(for: min(max(playhead, startTime), endTime))
        NSColor.white.setFill()
        NSRect(x: px - 1, y: trackRect.minY - 2, width: 2, height: trackRect.height + 4).fill()
        let ticker = NSBezierPath()
        ticker.move(to: NSPoint(x: px - 5, y: bounds.maxY - 1))
        ticker.line(to: NSPoint(x: px + 5, y: bounds.maxY - 1))
        ticker.line(to: NSPoint(x: px, y: bounds.maxY - 7))
        ticker.close()
        ticker.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let startX = x(for: startTime)
        let endX = x(for: endTime)
        let playheadX = x(for: min(max(playhead, startTime), endTime))
        let grab: CGFloat = 14
        // Closest handle wins when they overlap.
        if abs(point.x - startX) <= grab || abs(point.x - endX) <= grab {
            dragTarget = abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
        } else if abs(point.x - playheadX) <= grab
                    || (point.x >= startX && point.x <= endX && trackRect.insetBy(dx: 0, dy: -6).contains(point)) {
            dragTarget = .playhead
            updatePlayhead(at: point.x)
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
            playhead = max(playhead, startTime)
            onChange?(startTime)
        case .end:
            endTime = max(t, startTime + minimumRange)
            endTime = min(duration, endTime)
            playhead = min(playhead, endTime)
            onChange?(endTime)
        case .playhead:
            updatePlayhead(at: point.x)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = .none
    }

    override func resetCursorRects() {
        let selectedTrack = NSRect(
            x: x(for: startTime), y: trackRect.minY - 6,
            width: x(for: endTime) - x(for: startTime), height: trackRect.height + 12
        )
        addCursorRect(selectedTrack, cursor: .pointingHand)
        let playheadX = x(for: min(max(playhead, startTime), endTime))
        addCursorRect(
            NSRect(x: playheadX - 10, y: 0, width: 20, height: bounds.height),
            cursor: .openHand
        )
        for handleX in [x(for: startTime), x(for: endTime)] {
            let rect = NSRect(x: handleX - 10, y: 0, width: 20, height: bounds.height)
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    private func updatePlayhead(at x: CGFloat) {
        playhead = min(max(time(for: x), startTime), endTime)
        onChange?(playhead)
        needsDisplay = true
    }
}

/// Preview for centered crop presets and an interactive custom crop rectangle.
final class CropPreviewView: NSView {
    private enum DragTarget {
        case none, create, move
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var changesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var changesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var changesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var changesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    private static let minimumCropSize: CGFloat = 20
    private static let handleDiameter: CGFloat = 9
    private static let handleHitSize: CGFloat = 18

    var sourceSize: CGSize = .zero { didSet { needsDisplay = true } }
    var cropMode: EditorCropMode = .none {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var normalizedCustomCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private var dragStart: NSPoint?
    private var rectAtDragStart: NSRect?
    private var workingRect: NSRect?
    private var dragTarget: DragTarget = .none

    override func hitTest(_ point: NSPoint) -> NSView? {
        cropMode == .custom ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard cropMode == .custom else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        let crop = customCropRect
        dragTarget = target(at: point, crop: crop)
        dragStart = point
        rectAtDragStart = crop
        if dragTarget == .create {
            workingRect = NSRect(origin: point, size: .zero)
        } else {
            workingRect = crop
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let original = rectAtDragStart else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch dragTarget {
        case .create:
            workingRect = NSRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
        case .move:
            workingRect = moved(original, by: NSPoint(x: point.x - start.x, y: point.y - start.y))
        case .none:
            return
        default:
            workingRect = resized(original, toward: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let rect = workingRect else { return }
        let content = videoContentRect
        if rect.width >= Self.minimumCropSize, rect.height >= Self.minimumCropSize,
           content.width > 0, content.height > 0 {
            normalizedCustomCrop = CropGeometry.normalize(rect, within: content)
        }
        dragStart = nil
        rectAtDragStart = nil
        workingRect = nil
        dragTarget = .none
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        guard cropMode == .custom else { return }
        addCursorRect(videoContentRect, cursor: .crosshair)
        let crop = customCropRect
        addCursorRect(crop, cursor: .openHand)
        for (target, rect) in handleRects(for: crop, diameter: Self.handleHitSize) {
            let cursor: NSCursor
            switch target {
            case .left, .right, .topLeft, .bottomRight:
                cursor = .resizeLeftRight
            case .top, .bottom, .topRight, .bottomLeft:
                cursor = .resizeUpDown
            default:
                cursor = .crosshair
            }
            addCursorRect(rect, cursor: cursor)
        }
    }

    private var customCropRect: NSRect {
        workingRect ?? CropGeometry.denormalize(normalizedCustomCrop, within: videoContentRect)
    }

    private func target(at point: NSPoint, crop: NSRect) -> DragTarget {
        if let handle = handleRects(for: crop, diameter: Self.handleHitSize)
            .first(where: { $0.rect.contains(point) }) {
            return handle.target
        }
        return crop.contains(point) ? .move : .create
    }

    private func handleRects(for crop: NSRect, diameter: CGFloat) -> [(target: DragTarget, rect: NSRect)] {
        let radius = diameter / 2
        func rect(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - radius, y: y - radius, width: diameter, height: diameter)
        }
        return [
            (.topLeft, rect(crop.minX, crop.maxY)), (.top, rect(crop.midX, crop.maxY)),
            (.topRight, rect(crop.maxX, crop.maxY)), (.left, rect(crop.minX, crop.midY)),
            (.right, rect(crop.maxX, crop.midY)), (.bottomLeft, rect(crop.minX, crop.minY)),
            (.bottom, rect(crop.midX, crop.minY)), (.bottomRight, rect(crop.maxX, crop.minY))
        ]
    }

    private func moved(_ rect: NSRect, by delta: NSPoint) -> NSRect {
        let content = videoContentRect
        let x = min(max(rect.minX + delta.x, content.minX), content.maxX - rect.width)
        let y = min(max(rect.minY + delta.y, content.minY), content.maxY - rect.height)
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func resized(_ rect: NSRect, toward point: NSPoint) -> NSRect {
        let content = videoContentRect
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        if dragTarget.changesLeftEdge {
            minX = min(max(point.x, content.minX), maxX - Self.minimumCropSize)
        }
        if dragTarget.changesRightEdge {
            maxX = max(min(point.x, content.maxX), minX + Self.minimumCropSize)
        }
        if dragTarget.changesBottomEdge {
            minY = min(max(point.y, content.minY), maxY - Self.minimumCropSize)
        }
        if dragTarget.changesTopEdge {
            maxY = max(min(point.y, content.maxY), minY + Self.minimumCropSize)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        let content = videoContentRect
        return NSPoint(
            x: min(max(point.x, content.minX), content.maxX),
            y: min(max(point.y, content.minY), content.maxY)
        )
    }

    private var videoContentRect: NSRect {
        CropGeometry.contentRect(container: bounds, sourceSize: sourceSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = videoContentRect
        let crop: NSRect
        if cropMode == .custom {
            crop = customCropRect
        } else if let aspect = cropMode.aspectRatio, content.width / content.height > aspect {
            let width = content.height * aspect
            crop = NSRect(x: content.midX - width / 2, y: content.minY, width: width, height: content.height)
        } else if let aspect = cropMode.aspectRatio {
            let height = content.width / aspect
            crop = NSRect(x: content.minX, y: content.midY - height / 2, width: content.width, height: height)
        } else {
            return
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
        if cropMode == .custom {
            NSColor.systemYellow.setFill()
            for (_, handle) in handleRects(for: crop, diameter: Self.handleDiameter) {
                NSBezierPath(ovalIn: handle).fill()
            }
        }
    }
}

enum CropGeometry {
    static func contentRect(container: CGRect, sourceSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / sourceSize.width, container.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func normalize(_ selection: CGRect, within content: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        return CGRect(
            x: (selection.minX - content.minX) / content.width,
            y: (selection.minY - content.minY) / content.height,
            width: selection.width / content.width,
            height: selection.height / content.height
        )
    }

    static func denormalize(_ normalized: CGRect, within content: CGRect) -> CGRect {
        CGRect(
            x: content.minX + normalized.minX * content.width,
            y: content.minY + normalized.minY * content.height,
            width: normalized.width * content.width,
            height: normalized.height * content.height
        )
    }
}
