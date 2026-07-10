import AppKit
import CoreGraphics
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var selectionController: SelectionOverlayController?
    private var recorder: ScreenRecorder?
    private var recordingOverlay: RecordingOverlayController?
    private var settingsController: SettingsWindowController?
    private var trimController: TrimWindowController?
    private var libraryController: LibraryWindowController?
    private var lastSelectionPointWidth = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = CGRequestScreenCaptureAccess()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "GifCapture")
        }
        rebuildMenu()
        UpdateChecker.checkOnLaunch()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Robbie's GifCapture v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        if recorder?.isRecording == true {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Record New GIF…", action: #selector(startSelection), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Library…", action: #selector(openLibrary), keyEquivalent: "l")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Quit GifCapture", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func startSelection() {
        selectionController = SelectionOverlayController { [weak self] result in
            self?.selectionController = nil
            guard let self, let result else { return }
            self.beginRecording(result: result)
        }
        selectionController?.begin()
    }

    private func beginRecording(result: SelectionResult) {
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

        Task {
            do {
                try await recorder.start(
                    rect: result.rect,
                    display: result.display,
                    excludingWindowIDs: overlay.captureExcludedWindowIDs
                )
            } catch {
                await MainActor.run {
                    self.showError("Couldn't start recording", error)
                    self.recordingOverlay?.close()
                    self.recordingOverlay = nil
                    self.recorder = nil
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func stopRecording() {
        guard let recorder else { return }
        recordingOverlay?.close()
        recordingOverlay = nil
        rebuildMenu()

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

    private func presentTrimWindow(videoURL: URL) {
        let controller = TrimWindowController(
            videoURL: videoURL,
            pointWidth: lastSelectionPointWidth
        ) { [weak self] result in
            self?.trimController = nil
            switch result {
            case .saved(let gifURL):
                NSWorkspace.shared.activateFileViewerSelecting([gifURL])
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
