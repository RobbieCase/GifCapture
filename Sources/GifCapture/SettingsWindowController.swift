import AppKit
import CoreGraphics

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var settings = AppSettings.load()

    private let encoderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "90")
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let autoCopyCheckbox = NSButton(checkboxWithTitle: "Copy GIF to clipboard after saving", target: nil, action: nil)
    private let exportMP4Checkbox = NSButton(checkboxWithTitle: "Also save an MP4 copy", target: nil, action: nil)
    private let captureModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let followWindowCheckbox = NSButton(
        checkboxWithTitle: "Follow selected window while recording",
        target: nil,
        action: nil
    )
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

    private let sectionSelector = NSSegmentedControl(
        labels: ["Capture", "Output", "Shortcuts"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tabView = NSTabView()
    private let permissionStatusLabel = NSTextField(labelWithString: "Checking…")
    private let permissionSection = NSStackView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
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
        captureModePopup.addItems(withTitles: CaptureMode.allCases.map(\.displayName))

        countdownCheckbox.toolTip = "Wait three seconds after choosing the capture area"
        followWindowCheckbox.toolTip = "Experimental: follows window movement on its current display"
        reloadClickIndicatorModeItems()
        clickIndicatorColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        clickIndicatorColorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let ordinaryControls: [NSControl] = [
            encoderPopup, qualitySlider, fpsPopup, scalePopup,
            autoCopyCheckbox, exportMP4Checkbox,
            captureModePopup, followWindowCheckbox,
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
            $0.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }

        let qualityRow = NSStackView(views: [qualitySlider, qualityValueLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 10
        qualitySlider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let outputGrid = NSGridView(views: [
            [label("Encoder:"), encoderPopup],
            [label("Quality:"), qualityRow],
            [label("Frame rate:"), fpsPopup],
            [label("Output size:"), scalePopup],
        ])
        configureCardGrid(outputGrid)
        encoderPopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        fpsPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        scalePopup.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let exportOptions = NSStackView(views: [autoCopyCheckbox, exportMP4Checkbox])
        exportOptions.orientation = .vertical
        exportOptions.alignment = .leading
        exportOptions.spacing = 10

        var captureRows: [[NSView]] = [
            [label("Capture mode:"), captureModePopup],
            [label("Countdown:"), countdownCheckbox],
            [label("Cursor:"), cursorCheckbox],
        ]
        if FeatureFlags.followWindow {
            captureRows.insert([label("Window mode:"), followWindowCheckbox], at: 1)
        }
        let captureGrid = NSGridView(views: captureRows)
        configureCardGrid(captureGrid)
        captureModePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true

        clickIndicatorPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        clickIndicatorModifierPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        clickIndicatorModifierPopup.toolTip = "Modifier used by the third activation choice"

        let clickFeedbackGrid = NSGridView(views: [
            [label("Show indicator:"), clickIndicatorPopup],
            [label("Color:"), clickIndicatorColorWell],
        ])
        configureCardGrid(clickFeedbackGrid)

        let shortcutGrid = NSGridView(views: [
            [label("Start recording:"), startShortcutButton],
            [label("Open Library:"), libraryShortcutButton],
        ])
        configureCardGrid(shortcutGrid)

        let recordingShortcutGrid = NSGridView(views: [
            [label("Stop recording:"), stopShortcutButton],
            [label("Hold to zoom:"), zoomModifierPopup],
            [label("Hold to draw:"), drawModifierPopup],
            [label("Click indicator:"), clickIndicatorModifierPopup],
        ])
        configureCardGrid(recordingShortcutGrid)
        zoomModifierPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        drawModifierPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        permissionStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let settingsButton = NSButton(title: "Open System Settings…", target: self, action: #selector(openScreenRecordingSettings))
        settingsButton.bezelStyle = .rounded
        let permissionRow = NSStackView(views: [permissionStatusLabel, settingsButton])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 14

        permissionSection.setViews([
            sectionTitle("Screen Recording access is needed"),
            permissionRow,
            hint("Grant access, then quit and reopen GifCapture once so macOS applies the permission."),
        ], in: .top)
        permissionSection.orientation = .vertical
        permissionSection.alignment = .leading
        permissionSection.spacing = 8
        permissionSection.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        permissionSection.wantsLayer = true
        permissionSection.layer?.cornerRadius = 10
        permissionSection.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        permissionSection.widthAnchor.constraint(equalToConstant: 572).isActive = true

        let capturePage = page([
            card(
                title: "Capture area",
                subtitle: "Drag selection is the default. Window mode captures clean, shadowless bounds.",
                content: captureGrid
            ),
            card(
                title: "Mouse clicks",
                subtitle: "Optionally show a colored pulse around clicks in the recording.",
                content: clickFeedbackGrid
            ),
        ])

        let outputPage = page([
            card(
                title: "GIF output",
                subtitle: "Higher quality, frame rate, and scale create larger files.",
                content: outputGrid
            ),
            card(
                title: "After export",
                subtitle: "Choose what GifCapture should do with each finished recording.",
                content: exportOptions
            ),
        ])

        let shortcutsPage = page([
            card(
                title: "Global shortcuts",
                subtitle: "These work from any app while GifCapture is running.",
                content: shortcutGrid
            ),
            card(
                title: "While recording",
                subtitle: "Stop is a shortcut; zoom, drawing, and click feedback activate while held.",
                content: recordingShortcutGrid
            ),
        ])

        tabView.tabViewType = .noTabsNoBorder
        [capturePage, outputPage, shortcutsPage].enumerated().forEach { index, page in
            let item = NSTabViewItem(identifier: index)
            item.view = page
            tabView.addTabViewItem(item)
        }
        tabView.widthAnchor.constraint(equalToConstant: 572).isActive = true
        tabView.heightAnchor.constraint(equalToConstant: 360).isActive = true

        sectionSelector.selectedSegment = 0
        sectionSelector.segmentDistribution = .fillEqually
        sectionSelector.target = self
        sectionSelector.action = #selector(sectionChanged(_:))
        sectionSelector.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let stack = NSStackView(views: [sectionSelector, tabView, permissionSection])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
        syncControls()
    }

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        cancelShortcutCapture()
        tabView.selectTabViewItem(at: sender.selectedSegment)
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

    private func configureCardGrid(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 0).width = 128
    }

    private func page(_ cards: [NSView]) -> NSView {
        let page = NSView()
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor),
        ])
        return page
    }

    private func card(title: String, subtitle: String, content: NSView) -> NSView {
        let titleField = sectionTitle(title)
        let subtitleField = hint(subtitle, width: 520)
        let stack = NSStackView(views: [titleField, subtitleField, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 1
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        box.contentViewMargins = NSSize(width: 16, height: 14)
        box.contentView = stack
        box.widthAnchor.constraint(equalToConstant: 572).isActive = true
        // NSBox does not derive an intrinsic height from a replacement content view.
        // Give each card the height its controls need so tab pages never collapse.
        box.heightAnchor.constraint(equalToConstant: ceil(content.fittingSize.height) + 78).isActive = true
        return box
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func hint(_ text: String, width: CGFloat = 544) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 2
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func syncControls() {
        encoderPopup.selectItem(at: GifEncoder.allCases.firstIndex(of: settings.encoder) ?? 0)
        qualitySlider.integerValue = settings.quality
        qualityValueLabel.stringValue = String(settings.quality)
        fpsPopup.selectItem(at: AppSettings.fpsChoices.firstIndex(of: settings.fps) ?? 2)
        scalePopup.selectItem(at: OutputScale.allCases.firstIndex(of: settings.scale) ?? 0)
        autoCopyCheckbox.state = settings.autoCopyToClipboard ? .on : .off
        exportMP4Checkbox.state = settings.exportMP4 ? .on : .off
        captureModePopup.selectItem(at: CaptureMode.allCases.firstIndex(of: settings.captureMode) ?? 0)
        followWindowCheckbox.state = settings.followWindow ? .on : .off
        followWindowCheckbox.isEnabled = settings.captureMode == .window
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
        settings.autoCopyToClipboard = autoCopyCheckbox.state == .on
        settings.exportMP4 = exportMP4Checkbox.state == .on
        settings.captureMode = CaptureMode.allCases[max(0, captureModePopup.indexOfSelectedItem)]
        settings.followWindow = followWindowCheckbox.state == .on
        settings.countdownEnabled = countdownCheckbox.state == .on
        settings.showCursor = cursorCheckbox.state == .on
        settings.clickIndicatorMode = ClickIndicatorMode.allCases[max(0, clickIndicatorPopup.indexOfSelectedItem)]
        settings.clickIndicatorColor = IndicatorColor(clickIndicatorColorWell.color)
        settings.zoomModifier = newZoom
        settings.drawModifier = newDraw
        settings.clickIndicatorModifier = newClickModifier
        qualityValueLabel.stringValue = String(settings.quality)
        clickIndicatorColorWell.isEnabled = settings.clickIndicatorMode != .off
        followWindowCheckbox.isEnabled = settings.captureMode == .window
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
