import AppKit
import CoreGraphics

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var settings = AppSettings.load()

    private let encoderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "90")
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let countdownCheckbox = NSButton(checkboxWithTitle: "3 seconds", target: nil, action: nil)
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Show cursor in recording", target: nil, action: nil)
    private let clickIndicatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clickIndicatorColorWell = NSColorWell()

    private let startShortcutButton = ShortcutRecorderButton()
    private let libraryShortcutButton = ShortcutRecorderButton()
    private let stopShortcutButton = ShortcutRecorderButton()
    private let zoomModifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let drawModifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let permissionStatusLabel = NSTextField(labelWithString: "Checking…")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GifCapture Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func show() {
        settings = AppSettings.load()
        cancelShortcutCapture()
        syncControls()
        updatePermissionStatus()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updatePermissionStatus()
    }

    func windowWillClose(_ notification: Notification) {
        cancelShortcutCapture()
    }

    private func buildUI() {
        encoderPopup.addItems(withTitles: GifEncoder.allCases.map(\.displayName))
        qualitySlider.numberOfTickMarks = 0
        qualitySlider.isContinuous = true
        qualityValueLabel.alignment = .right
        fpsPopup.addItems(withTitles: AppSettings.fpsChoices.map { "\($0) fps" })
        scalePopup.addItems(withTitles: OutputScale.allCases.map(\.displayName))

        countdownCheckbox.toolTip = "Wait three seconds after choosing the capture area"
        clickIndicatorPopup.addItems(withTitles: ClickIndicatorMode.allCases.map(\.displayName))
        clickIndicatorColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        clickIndicatorColorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let ordinaryControls: [NSControl] = [
            encoderPopup, qualitySlider, fpsPopup, scalePopup,
            countdownCheckbox, cursorCheckbox, clickIndicatorPopup, clickIndicatorColorWell,
            zoomModifierPopup, drawModifierPopup,
        ]
        ordinaryControls.forEach {
            $0.target = self
            $0.action = #selector(controlChanged(_:))
        }

        configureShortcutButtons()

        let modifierTitles = RecordingModifier.allCases.map(\.displayName)
        zoomModifierPopup.addItems(withTitles: modifierTitles)
        drawModifierPopup.addItems(withTitles: modifierTitles)

        [startShortcutButton, libraryShortcutButton, stopShortcutButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }

        let qualityRow = NSStackView(views: [qualitySlider, qualityValueLabel])
        qualityRow.orientation = .horizontal
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let outputGrid = NSGridView(views: [
            [label("Encoder:"), encoderPopup],
            [label("Quality:"), qualityRow],
            [label("Frame rate:"), fpsPopup],
            [label("Output size:"), scalePopup],
        ])
        configure(grid: outputGrid)

        let captureGrid = NSGridView(views: [
            [label("Countdown:"), countdownCheckbox],
            [label("Cursor:"), cursorCheckbox],
            [label("Click indicator:"), clickIndicatorPopup],
            [label("Indicator color:"), clickIndicatorColorWell],
        ])
        configure(grid: captureGrid)

        let shortcutGrid = NSGridView(views: [
            [label("Start recording:"), startShortcutButton],
            [label("Open Library:"), libraryShortcutButton],
            [label("Stop recording:"), stopShortcutButton],
            [label("Hold to zoom:"), zoomModifierPopup],
            [label("Hold to draw:"), drawModifierPopup],
        ])
        configure(grid: shortcutGrid)

        permissionStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let settingsButton = NSButton(title: "Open System Settings…", target: self, action: #selector(openScreenRecordingSettings))
        settingsButton.bezelStyle = .rounded
        let permissionRow = NSStackView(views: [permissionStatusLabel, settingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 14

        let stack = NSStackView(views: [
            sectionTitle("Output"), outputGrid,
            hint("Higher quality, frame rate, and 2× size increase the GIF's file size."),
            separator(),
            sectionTitle("Capture"), captureGrid,
            hint("The countdown and click indicator are off by default. A modifier-click mode highlights only deliberate clicks."),
            separator(),
            sectionTitle("Key Bindings"), shortcutGrid,
            hint("Global shortcuts work from any app. Stop Recording is active only while a recording is in progress."),
            separator(),
            sectionTitle("Screen Recording Permission"), permissionRow,
            hint("After granting access in System Settings, quit and reopen GifCapture once so macOS applies the permission."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outputGrid.widthAnchor.constraint(equalToConstant: 460),
            captureGrid.widthAnchor.constraint(equalTo: outputGrid.widthAnchor),
            shortcutGrid.widthAnchor.constraint(equalTo: outputGrid.widthAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
        syncControls()
    }

    private func configureShortcutButtons() {
        startShortcutButton.onBeginCapture = { [weak self] in
            self?.libraryShortcutButton.cancelCapture()
            self?.stopShortcutButton.cancelCapture()
        }
        libraryShortcutButton.onBeginCapture = { [weak self] in
            self?.startShortcutButton.cancelCapture()
            self?.stopShortcutButton.cancelCapture()
        }
        stopShortcutButton.onBeginCapture = { [weak self] in
            self?.startShortcutButton.cancelCapture()
            self?.libraryShortcutButton.cancelCapture()
        }

        startShortcutButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != settings.openLibraryShortcut, shortcut != settings.stopRecordingShortcut else {
                showDuplicateShortcut()
                startShortcutButton.shortcut = settings.startRecordingShortcut
                return
            }
            settings.startRecordingShortcut = shortcut
            saveAndNotify()
        }
        libraryShortcutButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != settings.startRecordingShortcut, shortcut != settings.stopRecordingShortcut else {
                showDuplicateShortcut()
                libraryShortcutButton.shortcut = settings.openLibraryShortcut
                return
            }
            settings.openLibraryShortcut = shortcut
            saveAndNotify()
        }
        stopShortcutButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != settings.startRecordingShortcut, shortcut != settings.openLibraryShortcut else {
                showDuplicateShortcut()
                stopShortcutButton.shortcut = settings.stopRecordingShortcut
                return
            }
            settings.stopRecordingShortcut = shortcut
            saveAndNotify()
        }
    }

    private func configure(grid: NSGridView) {
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 2
        field.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    private func syncControls() {
        encoderPopup.selectItem(at: GifEncoder.allCases.firstIndex(of: settings.encoder) ?? 0)
        qualitySlider.integerValue = settings.quality
        qualityValueLabel.stringValue = String(settings.quality)
        fpsPopup.selectItem(at: AppSettings.fpsChoices.firstIndex(of: settings.fps) ?? 2)
        scalePopup.selectItem(at: OutputScale.allCases.firstIndex(of: settings.scale) ?? 0)
        countdownCheckbox.state = settings.countdownEnabled ? .on : .off
        cursorCheckbox.state = settings.showCursor ? .on : .off
        clickIndicatorPopup.selectItem(at: ClickIndicatorMode.allCases.firstIndex(of: settings.clickIndicatorMode) ?? 0)
        clickIndicatorColorWell.color = settings.clickIndicatorColor.nsColor
        clickIndicatorColorWell.isEnabled = settings.clickIndicatorMode != .off
        startShortcutButton.shortcut = settings.startRecordingShortcut
        libraryShortcutButton.shortcut = settings.openLibraryShortcut
        stopShortcutButton.shortcut = settings.stopRecordingShortcut
        zoomModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.zoomModifier) ?? 0)
        drawModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.drawModifier) ?? 2)
    }

    @objc private func controlChanged(_ sender: Any?) {
        let newZoom = RecordingModifier.allCases[max(0, zoomModifierPopup.indexOfSelectedItem)]
        let newDraw = RecordingModifier.allCases[max(0, drawModifierPopup.indexOfSelectedItem)]
        if newZoom == newDraw {
            NSSound.beep()
            if sender as AnyObject? === zoomModifierPopup {
                zoomModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.zoomModifier) ?? 0)
            } else {
                drawModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.drawModifier) ?? 2)
            }
            return
        }

        settings.encoder = GifEncoder.allCases[max(0, encoderPopup.indexOfSelectedItem)]
        settings.quality = qualitySlider.integerValue
        settings.fps = AppSettings.fpsChoices[max(0, fpsPopup.indexOfSelectedItem)]
        settings.scale = OutputScale.allCases[max(0, scalePopup.indexOfSelectedItem)]
        settings.countdownEnabled = countdownCheckbox.state == .on
        settings.showCursor = cursorCheckbox.state == .on
        settings.clickIndicatorMode = ClickIndicatorMode.allCases[max(0, clickIndicatorPopup.indexOfSelectedItem)]
        settings.clickIndicatorColor = IndicatorColor(clickIndicatorColorWell.color)
        settings.zoomModifier = newZoom
        settings.drawModifier = newDraw
        qualityValueLabel.stringValue = String(settings.quality)
        clickIndicatorColorWell.isEnabled = settings.clickIndicatorMode != .off
        saveAndNotify()
    }

    @objc private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updatePermissionStatus() {
        let granted = CGPreflightScreenCaptureAccess()
        permissionStatusLabel.stringValue = granted ? "Granted" : "Not Granted"
        permissionStatusLabel.textColor = granted ? .systemGreen : .systemRed
    }

    private func cancelShortcutCapture() {
        startShortcutButton.cancelCapture()
        libraryShortcutButton.cancelCapture()
        stopShortcutButton.cancelCapture()
    }

    private func saveAndNotify() {
        settings.save()
        NotificationCenter.default.post(name: .gifCaptureSettingsChanged, object: self)
    }

    private func showDuplicateShortcut() {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "Choose a different shortcut for Start Recording, Open Library, and Stop Recording."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
