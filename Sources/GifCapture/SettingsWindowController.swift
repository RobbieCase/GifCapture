import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var settings = AppSettings.load()

    private let encoderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "90")
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let startShortcutButton = ShortcutRecorderButton()
    private let libraryShortcutButton = ShortcutRecorderButton()
    private let zoomModifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let drawModifierPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
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
        startShortcutButton.cancelCapture()
        libraryShortcutButton.cancelCapture()
        syncControls()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        startShortcutButton.cancelCapture()
        libraryShortcutButton.cancelCapture()
    }

    private func buildUI() {
        encoderPopup.addItems(withTitles: GifEncoder.allCases.map(\.displayName))
        encoderPopup.target = self
        encoderPopup.action = #selector(controlChanged(_:))

        qualitySlider.numberOfTickMarks = 0
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(controlChanged(_:))
        qualityValueLabel.alignment = .right

        fpsPopup.addItems(withTitles: AppSettings.fpsChoices.map { "\($0) fps" })
        fpsPopup.target = self
        fpsPopup.action = #selector(controlChanged(_:))

        scalePopup.addItems(withTitles: OutputScale.allCases.map(\.displayName))
        scalePopup.target = self
        scalePopup.action = #selector(controlChanged(_:))

        startShortcutButton.onBeginCapture = { [weak self] in
            self?.libraryShortcutButton.cancelCapture()
        }
        libraryShortcutButton.onBeginCapture = { [weak self] in
            self?.startShortcutButton.cancelCapture()
        }
        startShortcutButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != self.settings.openLibraryShortcut else {
                self.showDuplicateShortcut()
                self.startShortcutButton.shortcut = self.settings.startRecordingShortcut
                return
            }
            self.settings.startRecordingShortcut = shortcut
            self.saveAndNotify()
        }
        libraryShortcutButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            guard shortcut != self.settings.startRecordingShortcut else {
                self.showDuplicateShortcut()
                self.libraryShortcutButton.shortcut = self.settings.openLibraryShortcut
                return
            }
            self.settings.openLibraryShortcut = shortcut
            self.saveAndNotify()
        }

        let modifierTitles = RecordingModifier.allCases.map(\.displayName)
        zoomModifierPopup.addItems(withTitles: modifierTitles)
        zoomModifierPopup.target = self
        zoomModifierPopup.action = #selector(controlChanged(_:))
        drawModifierPopup.addItems(withTitles: modifierTitles)
        drawModifierPopup.target = self
        drawModifierPopup.action = #selector(controlChanged(_:))

        startShortcutButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        libraryShortcutButton.widthAnchor.constraint(equalToConstant: 150).isActive = true

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

        let shortcutGrid = NSGridView(views: [
            [label("Start recording:"), startShortcutButton],
            [label("Open Library:"), libraryShortcutButton],
            [label("Hold to zoom:"), zoomModifierPopup],
            [label("Hold to draw:"), drawModifierPopup],
        ])
        configure(grid: shortcutGrid)

        let outputHint = hint(
            "Changes apply to the next recording. Higher quality, frame rate, and 2× size increase the GIF's file size."
        )
        let shortcutHint = hint(
            "Global shortcuts work from any app. During recording, hold the selected modifier to zoom or hold it while dragging to draw."
        )

        let stack = NSStackView(views: [
            sectionTitle("Output"), outputGrid, outputHint,
            separator(),
            sectionTitle("Key Bindings"), shortcutGrid, shortcutHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outputGrid.widthAnchor.constraint(equalToConstant: 440),
            shortcutGrid.widthAnchor.constraint(equalTo: outputGrid.widthAnchor),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
        syncControls()
    }

    private func configure(grid: NSGridView) {
        grid.rowSpacing = 10
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
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return box
    }

    private func syncControls() {
        encoderPopup.selectItem(at: GifEncoder.allCases.firstIndex(of: settings.encoder) ?? 0)
        qualitySlider.integerValue = settings.quality
        qualityValueLabel.stringValue = String(settings.quality)
        fpsPopup.selectItem(at: AppSettings.fpsChoices.firstIndex(of: settings.fps) ?? 2)
        scalePopup.selectItem(at: OutputScale.allCases.firstIndex(of: settings.scale) ?? 0)
        startShortcutButton.shortcut = settings.startRecordingShortcut
        libraryShortcutButton.shortcut = settings.openLibraryShortcut
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
        settings.zoomModifier = newZoom
        settings.drawModifier = newDraw
        qualityValueLabel.stringValue = String(settings.quality)
        saveAndNotify()
    }

    private func saveAndNotify() {
        settings.save()
        NotificationCenter.default.post(name: .gifCaptureSettingsChanged, object: self)
    }

    private func showDuplicateShortcut() {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "Choose a different shortcut for Start Recording and Open Library."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
