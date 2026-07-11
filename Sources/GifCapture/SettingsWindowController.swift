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
    private let clickIndicatorModifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let permissionStatusLabel = NSTextField(labelWithString: "Checking…")
    private let permissionSeparator = NSBox()
    private let permissionSection = NSStackView()

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
        reloadClickIndicatorModeItems()
        clickIndicatorColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        clickIndicatorColorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let ordinaryControls: [NSControl] = [
            encoderPopup, qualitySlider, fpsPopup, scalePopup,
            countdownCheckbox, cursorCheckbox, clickIndicatorPopup, clickIndicatorColorWell,
            zoomModifierPopup, drawModifierPopup, clickIndicatorModifierPopup,
        ]
        ordinaryControls.forEach {
            $0.target = self
            $0.action = #selector(controlChanged(_:))
        }

        configureShortcutButtons()

        let modifierTitles = RecordingModifier.allCases.map(\.displayName)
        zoomModifierPopup.addItems(withTitles: modifierTitles)
        drawModifierPopup.addItems(withTitles: modifierTitles)
        clickIndicatorModifierPopup.addItems(withTitles: modifierTitles)

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
        configureLeftAligned(grid: captureGrid)

        clickIndicatorPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        clickIndicatorModifierPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        clickIndicatorModifierPopup.toolTip = "Modifier used by the third activation choice"

        let shortcutGrid = NSGridView(views: [
            [label("Start recording:"), startShortcutButton],
            [label("Open Library:"), libraryShortcutButton],
            [label("Stop recording:"), stopShortcutButton],
            [label("Hold to zoom:"), zoomModifierPopup],
            [label("Hold to draw:"), drawModifierPopup],
            [label("Click indicator:"), clickIndicatorModifierPopup],
        ])
        configureLeftAligned(grid: shortcutGrid)

        permissionStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let settingsButton = NSButton(title: "Open System Settings…", target: self, action: #selector(openScreenRecordingSettings))
        settingsButton.bezelStyle = .rounded
        let permissionRow = NSStackView(views: [permissionStatusLabel, settingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 14

        permissionSeparator.boxType = .separator
        permissionSeparator.widthAnchor.constraint(equalToConstant: 460).isActive = true
        permissionSection.setViews([
            sectionTitle("Screen Recording Permission"),
            permissionRow,
            hint("After granting access in System Settings, quit and reopen GifCapture once so macOS applies the permission."),
        ], in: .top)
        permissionSection.orientation = .vertical
        permissionSection.alignment = .leading
        permissionSection.spacing = 9

        let stack = NSStackView(views: [
            sectionTitle("Output"), outputGrid,
            hint("Higher quality, frame rate, and 2× size increase the GIF's file size."),
            separator(),
            sectionTitle("Capture"), captureGrid,
            hint("The countdown and click highlighting are off by default. Indicator color applies when click highlighting is enabled."),
            separator(),
            sectionTitle("Key Bindings"), shortcutGrid,
            hint("Stop Recording is active only while recording. The click modifier is available when modifier-click highlighting is selected above."),
            permissionSeparator,
            permissionSection,
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

    private func configureLeftAligned(grid: NSGridView) {
        configure(grid: grid)
        grid.columnSpacing = 8
        grid.column(at: 0).width = 112
        grid.column(at: 1).width = 340
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
        reloadClickIndicatorModeItems()
        clickIndicatorPopup.selectItem(at: ClickIndicatorMode.allCases.firstIndex(of: settings.clickIndicatorMode) ?? 0)
        clickIndicatorColorWell.color = settings.clickIndicatorColor.nsColor
        clickIndicatorColorWell.isEnabled = settings.clickIndicatorMode != .off
        startShortcutButton.shortcut = settings.startRecordingShortcut
        libraryShortcutButton.shortcut = settings.openLibraryShortcut
        stopShortcutButton.shortcut = settings.stopRecordingShortcut
        zoomModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.zoomModifier) ?? 0)
        drawModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.drawModifier) ?? 2)
        clickIndicatorModifierPopup.selectItem(
            at: RecordingModifier.allCases.firstIndex(of: settings.clickIndicatorModifier) ?? 1
        )
        clickIndicatorModifierPopup.isEnabled = settings.clickIndicatorMode == .modifierClick
    }

    @objc private func controlChanged(_ sender: Any?) {
        let newZoom = RecordingModifier.allCases[max(0, zoomModifierPopup.indexOfSelectedItem)]
        let newDraw = RecordingModifier.allCases[max(0, drawModifierPopup.indexOfSelectedItem)]
        let newClickModifier = RecordingModifier.allCases[max(0, clickIndicatorModifierPopup.indexOfSelectedItem)]
        if Set([newZoom, newDraw, newClickModifier]).count != 3 {
            NSSound.beep()
            zoomModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.zoomModifier) ?? 0)
            drawModifierPopup.selectItem(at: RecordingModifier.allCases.firstIndex(of: settings.drawModifier) ?? 2)
            clickIndicatorModifierPopup.selectItem(
                at: RecordingModifier.allCases.firstIndex(of: settings.clickIndicatorModifier) ?? 1
            )
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
        settings.clickIndicatorModifier = newClickModifier
        qualityValueLabel.stringValue = String(settings.quality)
        clickIndicatorColorWell.isEnabled = settings.clickIndicatorMode != .off
        clickIndicatorModifierPopup.isEnabled = settings.clickIndicatorMode == .modifierClick
        reloadClickIndicatorModeItems()
        clickIndicatorPopup.selectItem(at: ClickIndicatorMode.allCases.firstIndex(of: settings.clickIndicatorMode) ?? 0)
        saveAndNotify()
    }

    @objc private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updatePermissionStatus() {
        let granted = CGPreflightScreenCaptureAccess()
        permissionStatusLabel.stringValue = "Not Granted"
        permissionStatusLabel.textColor = .systemRed
        let shouldHide = granted
        guard permissionSection.isHidden != shouldHide else { return }
        permissionSection.isHidden = shouldHide
        permissionSeparator.isHidden = shouldHide
        window?.contentView?.layoutSubtreeIfNeeded()
        if let size = window?.contentView?.fittingSize, size.width > 0, size.height > 0 {
            window?.setContentSize(size)
        }
    }

    private func reloadClickIndicatorModeItems() {
        let selected = clickIndicatorPopup.indexOfSelectedItem
        clickIndicatorPopup.removeAllItems()
        clickIndicatorPopup.addItems(withTitles: ClickIndicatorMode.allCases.map {
            $0.displayName(modifier: settings.clickIndicatorModifier)
        })
        if selected >= 0, selected < clickIndicatorPopup.numberOfItems {
            clickIndicatorPopup.selectItem(at: selected)
        }
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
