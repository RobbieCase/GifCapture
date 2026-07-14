import AppKit
import CoreGraphics
import ScreenCaptureKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RecordingPhase {
        case idle
        case starting
        case recording
        case stopping
    }

    private var statusItem: NSStatusItem!
    private var selectionController: SelectionOverlayController?
    private var countdownController: CountdownOverlayController?
    private var recorder: ScreenRecorder?
    private var recordingPhase: RecordingPhase = .idle
    private var recordingOverlay: RecordingOverlayController?
    private var settingsController: SettingsWindowController?
    private var trimController: TrimWindowController?
    private var libraryController: LibraryWindowController?
    private var followWindowTimer: Timer?
    private var followLastRect: CGRect?
    private var lastSelectionPointWidth = 0
    private let hotKeyManager = GlobalHotKeyManager()
    private var isCapturingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "GifCapture")
        }
        rebuildMenu()
        UNUserNotificationCenter.current().delegate = self
        configureGlobalShortcuts(showErrors: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged(_:)),
            name: .gifCaptureSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(shortcutCaptureBegan(_:)),
            name: .shortcutCaptureBegan, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(shortcutCaptureEnded(_:)),
            name: .shortcutCaptureEnded, object: nil
        )
        UpdateChecker.checkOnLaunch()
        handleQAHook()
    }

    /// Local QA: GIFCAPTURE_QA=library|record|settings|trim|annotations drives the app into the
    /// named flow after launch and exits, so smoke tests can run headless.
    private func handleQAHook() {
        guard let mode = ProcessInfo.processInfo.environment["GIFCAPTURE_QA"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            switch mode {
            case "library": self?.openLibrary()
            case "record": self?.startSelection()
            case "settings": self?.openSettings()
            case "trim":
                if let path = ProcessInfo.processInfo.environment["GIFCAPTURE_QA_VIDEO"] {
                    self?.lastSelectionPointWidth = 640
                    self?.presentTrimWindow(videoURL: URL(fileURLWithPath: path))
                }
            case "annotations":
                if let self, let screen = NSScreen.main {
                    let rect = CGRect(x: 180, y: 150, width: 640, height: 420)
                    let overlay = RecordingOverlayController(screen: screen, topLeftRect: rect) {}
                    overlay.show()
                    self.recordingOverlay = overlay
                }
            default: break
            }
            let hold = Double(ProcessInfo.processInfo.environment["GIFCAPTURE_QA_HOLD"] ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                let visible = NSApp.windows.filter(\.isVisible).count
                print("QA OK mode=\(mode) visibleWindows=\(visible)")
                exit(0)
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Robbie's GifCapture v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        if countdownController != nil {
            menu.addItem(withTitle: "Cancel Countdown", action: #selector(cancelCountdown), keyEquivalent: "")
        } else if recordingOverlay != nil {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Record New GIF…", action: #selector(startSelection), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let libraryItem = NSMenuItem(title: "Library…", action: #selector(openLibrary), keyEquivalent: "")
        libraryItem.image = libraryMenuImage()
        menu.addItem(libraryItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Quit GifCapture", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func startSelection() {
        guard recordingPhase == .idle,
              recorder == nil, selectionController == nil, countdownController == nil else { return }
        guard requestScreenRecordingAccessIfNeeded() else { return }
        let captureMode = AppSettings.load().captureMode
        selectionController = SelectionOverlayController(captureMode: captureMode) { [weak self] result in
            self?.selectionController = nil
            guard let self, let result else { return }
            self.beginRecording(result: result)
        }
        selectionController?.begin()
    }

    /// Only ask for protected access in direct response to Record. Requesting it
    /// during every launch creates a permission nag before the user does anything.
    private func requestScreenRecordingAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording access is needed"
        alert.informativeText = "Allow GifCapture under Privacy & Security → Screen & System Audio Recording, then try recording again."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func beginRecording(result: SelectionResult) {
        let settings = AppSettings.load()
        guard settings.countdownEnabled else {
            beginRecordingNow(result: result, settings: settings)
            return
        }

        let countdown = CountdownOverlayController(
            screen: result.screen,
            topLeftRect: result.rect
        ) { [weak self] completed in
            guard let self else { return }
            self.countdownController = nil
            self.rebuildMenu()
            guard completed else { return }
            self.beginRecordingNow(result: result, settings: AppSettings.load())
        }
        countdownController = countdown
        rebuildMenu()
        countdown.show()
    }

    private func beginRecordingNow(result: SelectionResult, settings: AppSettings) {
        let result = refreshedWindowSelection(result)
        let recorder = ScreenRecorder()
        self.recorder = recorder
        recordingPhase = .starting
        lastSelectionPointWidth = Int(result.rect.width)

        let overlay = RecordingOverlayController(screen: result.screen, topLeftRect: result.rect) { [weak self] in
            self?.stopRecording()
        }
        overlay.onZoomChange = { [weak recorder] active in
            recorder?.zoomActive = active
        }
        overlay.show()
        recordingOverlay = overlay
        rebuildMenu()
        configureGlobalShortcuts(showErrors: false)

        Task {
            do {
                let shouldFollow = FeatureFlags.followWindow
                    && settings.followWindow
                    && result.captureMode == .window
                    && result.windowID != nil
                try await recorder.start(
                    rect: result.rect,
                    display: result.display,
                    excludingWindowIDs: overlay.captureExcludedWindowIDs,
                    showsCursor: settings.showCursor,
                    followsWindow: shouldFollow
                )
                let stopWasRequested = await MainActor.run { () -> Bool in
                    guard self.recorder === recorder else { return true }
                    if self.recordingPhase == .stopping { return true }
                    self.recordingPhase = .recording
                    if shouldFollow {
                        self.startFollowingWindow(result: result, recorder: recorder, overlay: overlay)
                    }
                    return false
                }
                if stopWasRequested {
                    await self.finishRecording(recorder)
                }
            } catch {
                await MainActor.run {
                    guard self.recorder === recorder else { return }
                    self.stopFollowingWindow()
                    if self.recordingPhase != .stopping {
                        self.showError("Couldn't start recording", error)
                    }
                    self.recordingOverlay?.close()
                    self.recordingOverlay = nil
                    self.recorder = nil
                    self.recordingPhase = .idle
                    self.rebuildMenu()
                    self.configureGlobalShortcuts(showErrors: false)
                }
            }
        }
    }

    @objc private func stopRecording() {
        guard let recorder else { return }
        let shouldStopNow: Bool
        switch recordingPhase {
        case .starting:
            // Startup is asynchronous. Mark the request and let the startup task
            // stop the stream immediately after ScreenCaptureKit finishes opening it.
            recordingPhase = .stopping
            shouldStopNow = false
        case .recording:
            recordingPhase = .stopping
            shouldStopNow = true
        case .stopping, .idle:
            return
        }
        stopFollowingWindow()
        recordingOverlay?.close()
        recordingOverlay = nil
        rebuildMenu()
        configureGlobalShortcuts(showErrors: false)

        if shouldStopNow {
            Task { await self.finishRecording(recorder) }
        }
    }

    private func finishRecording(_ recorder: ScreenRecorder) async {
        do {
            let videoURL = try await recorder.stop()
            await MainActor.run {
                guard self.recorder === recorder else { return }
                self.recorder = nil
                self.recordingPhase = .idle
                self.rebuildMenu()
                self.presentTrimWindow(videoURL: videoURL)
            }
        } catch {
            await MainActor.run {
                guard self.recorder === recorder else { return }
                self.recorder = nil
                self.recordingPhase = .idle
                self.rebuildMenu()
                self.showError("Couldn't finish recording", error)
            }
        }
    }

    private func refreshedWindowSelection(_ result: SelectionResult) -> SelectionResult {
        guard result.captureMode == .window,
              let windowID = result.windowID,
              let rect = WindowCaptureGeometry.displayRelativeRect(
                  for: windowID,
                  displayID: result.display.displayID
              ) else { return result }
        return SelectionResult(
            rect: rect,
            display: result.display,
            screen: result.screen,
            captureMode: result.captureMode,
            windowID: windowID
        )
    }

    private func startFollowingWindow(
        result: SelectionResult,
        recorder: ScreenRecorder,
        overlay: RecordingOverlayController
    ) {
        stopFollowingWindow()
        guard let windowID = result.windowID else { return }
        followLastRect = result.rect
        let fixedSize = result.rect.size
        let displayID = result.display.displayID

        let refreshRate = min(120, max(60, result.screen.maximumFramesPerSecond))
        let timer = Timer(timeInterval: 1.0 / Double(refreshRate), repeats: true) { [weak self, weak recorder, weak overlay] _ in
            Task { @MainActor in
                guard let self, let recorder, let overlay,
                      let rect = WindowCaptureGeometry.displayRelativeRect(
                          for: windowID,
                          displayID: displayID,
                          fixedSize: fixedSize
                      ), rect != self.followLastRect else { return }
                recorder.setFollowCaptureRect(rect)
                overlay.updateCaptureRect(rect)
                self.followLastRect = rect
            }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        followWindowTimer = timer
    }

    private func stopFollowingWindow() {
        followWindowTimer?.invalidate()
        followWindowTimer = nil
        followLastRect = nil
    }

    @objc private func cancelCountdown() {
        countdownController?.cancel()
    }

    private func presentTrimWindow(videoURL: URL) {
        let controller = TrimWindowController(
            videoURL: videoURL,
            outputWidth: .screenPoints(lastSelectionPointWidth)
        ) { [weak self] result in
            self?.trimController = nil
            switch result {
            case .saved(let gifURL, let mp4URL):
                if AppSettings.load().autoCopyToClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([gifURL as NSURL])
                }
                CaptureNotifier.notifySaved(gifURL: gifURL, mp4URL: mp4URL)
                self?.openLibrary()
            case .cancelled:
                break
            case .failed(let error):
                self?.showError("Couldn't create GIF", error)
            }
        }
        trimController = controller
        controller.show()
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.show()
    }

    @objc private func openLibrary() {
        if libraryController == nil {
            libraryController = LibraryWindowController()
        }
        libraryController?.show()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.checkInteractive()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        guard !isCapturingShortcut else { return }
        configureGlobalShortcuts(showErrors: true)
    }

    @objc private func shortcutCaptureBegan(_ notification: Notification) {
        isCapturingShortcut = true
        hotKeyManager.clear()
    }

    @objc private func shortcutCaptureEnded(_ notification: Notification) {
        isCapturingShortcut = false
        configureGlobalShortcuts(showErrors: true)
    }

    private func configureGlobalShortcuts(showErrors: Bool) {
        hotKeyManager.clear()
        let settings = AppSettings.load()
        var unavailable: [String] = []
        if !hotKeyManager.register(id: 1, shortcut: settings.startRecordingShortcut, action: { [weak self] in
            self?.startSelection()
        }) {
            unavailable.append("Start Recording (\(settings.startRecordingShortcut.displayName))")
        }
        if !hotKeyManager.register(id: 2, shortcut: settings.openLibraryShortcut, action: { [weak self] in
            self?.openLibrary()
        }) {
            unavailable.append("Open Library (\(settings.openLibraryShortcut.displayName))")
        }
        if recordingOverlay != nil,
           !hotKeyManager.register(id: 3, shortcut: settings.stopRecordingShortcut, action: { [weak self] in
               self?.stopRecording()
           }) {
            unavailable.append("Stop Recording (\(settings.stopRecordingShortcut.displayName))")
        }
        guard showErrors, !unavailable.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Shortcut unavailable"
        alert.informativeText = unavailable.joined(separator: "\n")
            + "\n\nThat shortcut may already be registered by macOS or another app."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func libraryMenuImage() -> NSImage? {
        for resource in ["library-icon-v2", "library-icon"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = true
            image.accessibilityDescription = "Library"
            return image
        }
        return NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Library")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Notification click -> reveal in Finder

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo[CaptureNotifier.revealPathKey] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Menu bar apps count as "frontmost"; still show the banner.
        completionHandler([.banner])
    }
}
