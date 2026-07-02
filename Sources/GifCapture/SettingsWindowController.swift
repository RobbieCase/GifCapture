import AppKit

final class SettingsWindowController: NSWindowController {
    private var settings = AppSettings.load()

    private let encoderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 90, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "90")
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GifCapture Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    func show() {
        settings = AppSettings.load()
        syncControls()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        encoderPopup.addItems(withTitles: GifEncoder.allCases.map(\.displayName))
        encoderPopup.target = self
        encoderPopup.action = #selector(controlChanged)

        qualitySlider.numberOfTickMarks = 0
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(controlChanged)
        qualityValueLabel.alignment = .right

        fpsPopup.addItems(withTitles: AppSettings.fpsChoices.map { "\($0) fps" })
        fpsPopup.target = self
        fpsPopup.action = #selector(controlChanged)

        scalePopup.addItems(withTitles: OutputScale.allCases.map(\.displayName))
        scalePopup.target = self
        scalePopup.action = #selector(controlChanged)

        let qualityRow = NSStackView(views: [qualitySlider, qualityValueLabel])
        qualityRow.orientation = .horizontal
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let grid = NSGridView(views: [
            [label("Encoder:"), encoderPopup],
            [label("Quality:"), qualityRow],
            [label("Frame rate:"), fpsPopup],
            [label("Output size:"), scalePopup],
        ])
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let hint = NSTextField(wrappingLabelWithString:
            "Changes apply to the next recording. Higher quality, frame rate, and 2× size all increase the GIF's file size.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            grid.widthAnchor.constraint(equalToConstant: 380),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
        syncControls()
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func syncControls() {
        encoderPopup.selectItem(at: GifEncoder.allCases.firstIndex(of: settings.encoder) ?? 0)
        qualitySlider.integerValue = settings.quality
        qualityValueLabel.stringValue = String(settings.quality)
        fpsPopup.selectItem(at: AppSettings.fpsChoices.firstIndex(of: settings.fps) ?? 2)
        scalePopup.selectItem(at: OutputScale.allCases.firstIndex(of: settings.scale) ?? 0)
    }

    @objc private func controlChanged() {
        settings.encoder = GifEncoder.allCases[max(0, encoderPopup.indexOfSelectedItem)]
        settings.quality = qualitySlider.integerValue
        settings.fps = AppSettings.fpsChoices[max(0, fpsPopup.indexOfSelectedItem)]
        settings.scale = OutputScale.allCases[max(0, scalePopup.indexOfSelectedItem)]
        qualityValueLabel.stringValue = String(settings.quality)
        settings.save()
    }
}
