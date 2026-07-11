import AppKit
import CoreGraphics
import ScreenCaptureKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recentCapturesMenu = NSMenu()
    private var statusItem: NSStatusItem!
    private var selectionController: SelectionOverlayController?
    private var countdownController: CountdownOverlayController?
    private var recorder: ScreenRecorder?
    private var recordingOverlay: RecordingOverlayController?
    private var settingsController: SettingsWindowController?
    private var trimController: TrimWindowController?
    private var libraryController: LibraryWindowController?
    private var lastSelectionPointWidth = 0
    private let hotKeyManager = GlobalHotKeyManager()
    private var isCapturingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGRequestScreenCaptureAccess()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "GifCapture")
        }
        rebuildMenu()
        recentCapturesMenu.delegate = self
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
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recentItem.submenu = recentCapturesMenu
        menu.addItem(recentItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Quit GifCapture", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func startSelection() {
        guard recorder == nil, selectionController == nil, countdownController == nil else { return }
        selectionController = SelectionOverlayController { [weak self] result in
            self?.selectionController = nil
            guard let self, let result else { return }
            self.beginRecording(result: result)
        }
        selectionController?.begin()
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
        let recorder = ScreenRecorder()
        self.recorder = recorder
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
                try await recorder.start(
                    rect: result.rect,
                    display: result.display,
                    excludingWindowIDs: overlay.captureExcludedWindowIDs,
                    showsCursor: settings.showCursor
                )
            } catch {
                await MainActor.run {
                    self.showError("Couldn't start recording", error)
                    self.recordingOverlay?.close()
                    self.recordingOverlay = nil
                    self.recorder = nil
                    self.rebuildMenu()
                    self.configureGlobalShortcuts(showErrors: false)
                }
            }
        }
    }

    @objc private func stopRecording() {
        guard let recorder else { return }
        recordingOverlay?.close()
        recordingOverlay = nil
        rebuildMenu()
        configureGlobalShortcuts(showErrors: false)

        Task {
            do {
                let videoURL = try await recorder.stop()
                self.recorder = nil
                await MainActor.run {
                    self.rebuildMenu()
                    self.presentTrimWindow(videoURL: videoURL)
                }
            } catch {
                self.recorder = nil
                await MainActor.run {
                    self.rebuildMenu()
                    self.showError("Couldn't finish recording", error)
                }
            }
        }
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

    // MARK: - Recent captures

    @objc private func recentCaptureCopy(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    @objc private func recentCaptureReveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func recentCaptures(limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: GifConverter.outputDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var gifs: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "gif" {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            gifs.append((url, date))
        }
        return gifs.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Recent Captures submenu population

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentCapturesMenu else { return }
        menu.removeAllItems()
        let recents = recentCaptures(limit: 5)
        guard !recents.isEmpty else {
            let empty = menu.addItem(withTitle: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for url in recents {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(recentCaptureCopy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = "Copy to clipboard — hold Option to reveal in Finder"

            let alternate = NSMenuItem(title: "Reveal \"\(url.lastPathComponent)\"", action: #selector(recentCaptureReveal(_:)), keyEquivalent: "")
            alternate.target = self
            alternate.representedObject = url
            alternate.isAlternate = true
            alternate.keyEquivalentModifierMask = .option
            menu.addItem(alternate)
        }
    }
}

// MARK: - Notification click -> reveal in Finder

extension AppDelegate: UNUserNotificationCenterDelegate {
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
