import AppKit

final class SelectionOverlayView: NSView {
    private struct CaptureSizePreset {
        let id: String
        let title: String
        let size: NSSize

        static let builtIns: [CaptureSizePreset] = [
            CaptureSizePreset(id: "builtin:product-demo", title: "Product Demo — 1280 × 720", size: NSSize(width: 1280, height: 720)),
            CaptureSizePreset(id: "builtin:product-screenshot", title: "Product Screenshot — 1200 × 800", size: NSSize(width: 1200, height: 800)),
            CaptureSizePreset(id: "builtin:presentation", title: "Presentation — 1024 × 768", size: NSSize(width: 1024, height: 768)),
            CaptureSizePreset(id: "builtin:square-product", title: "Square Product — 800 × 800", size: NSSize(width: 800, height: 800)),
            CaptureSizePreset(id: "builtin:square-social", title: "Square Social — 1080 × 1080", size: NSSize(width: 1080, height: 1080)),
            CaptureSizePreset(id: "builtin:social-landscape", title: "Social Landscape — 1200 × 628", size: NSSize(width: 1200, height: 628)),
            CaptureSizePreset(id: "builtin:marketing-banner", title: "Marketing Banner — 1200 × 400", size: NSSize(width: 1200, height: 400)),
            CaptureSizePreset(id: "builtin:email-hero", title: "Email Hero — 600 × 300", size: NSSize(width: 600, height: 300)),
            CaptureSizePreset(id: "builtin:billboard", title: "Billboard Ad — 970 × 250", size: NSSize(width: 970, height: 250)),
            CaptureSizePreset(id: "builtin:leaderboard", title: "Leaderboard Ad — 728 × 90", size: NSSize(width: 728, height: 90)),
            CaptureSizePreset(id: "builtin:large-rectangle", title: "Large Rectangle Ad — 336 × 280", size: NSSize(width: 336, height: 280)),
            CaptureSizePreset(id: "builtin:medium-rectangle", title: "Medium Rectangle Ad — 300 × 250", size: NSSize(width: 300, height: 250)),
            CaptureSizePreset(id: "builtin:half-page", title: "Half Page Ad — 300 × 600", size: NSSize(width: 300, height: 600)),
            CaptureSizePreset(id: "builtin:wide-skyscraper", title: "Wide Skyscraper Ad — 160 × 600", size: NSSize(width: 160, height: 600)),
            CaptureSizePreset(id: "builtin:mobile-banner", title: "Mobile Banner Ad — 320 × 50", size: NSSize(width: 320, height: 50)),
        ]
    }

    private struct SavedCaptureSize: Codable {
        let id: String
        let name: String
        let width: Double
        let height: Double

        var preset: CaptureSizePreset {
            CaptureSizePreset(
                id: "saved:\(id)",
                title: "\(name) — \(Int(width)) × \(Int(height))",
                size: NSSize(width: width, height: height)
            )
        }
    }

    private enum SavedCaptureSizeStore {
        private static let key = "savedCaptureSizes"

        static func load() -> [SavedCaptureSize] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let sizes = try? JSONDecoder().decode([SavedCaptureSize].self, from: data) else { return [] }
            return sizes
        }

        static func save(_ sizes: [SavedCaptureSize]) {
            guard let data = try? JSONEncoder().encode(sizes) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var screen: NSScreen?
    var captureMode: CaptureMode = .drag
    var windowCandidates: [WindowSelectionCandidate] = []
    /// Fires with the confirmed rect in view coordinates (bottom-left origin).
    var onConfirm: ((CGRect, CGWindowID?) -> Void)?
    var onCancel: (() -> Void)?
    /// Fires when the user starts a fresh drag on this screen, so other screens can clear.
    var onSelectionBegan: (() -> Void)?

    private enum Mode { case idle, creating, adjusting }

    private enum Handle {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, move, none
    }

    private var mode: Mode = .idle
    private var rect: NSRect = .zero
    private var dragStart: NSPoint = .zero
    private var rectAtDragStart: NSRect = .zero
    private var activeHandle: Handle = .none
    private var selectedWindowID: CGWindowID?
    private var hoveredWindowLabel: String?

    private let handleSize: CGFloat = 9
    private let hitTolerance: CGFloat = 10

    private lazy var recordButton: NSButton = {
        let button = NSButton(title: "Record", target: self, action: #selector(recordTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.isHidden = true
        addSubview(button)
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        button.bezelStyle = .rounded
        button.isHidden = true
        addSubview(button)
        return button
    }()

    private lazy var sizePresetPopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        populatePresetMenu(popup, selecting: "custom")
        popup.target = self
        popup.action = #selector(sizePresetChanged(_:))
        popup.toolTip = "Choose a common product, marketing, or advertising frame size"
        popup.isHidden = captureMode != .drag
        addSubview(popup)
        return popup
    }()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updatePresetAvailability()
        layoutButtons()
    }

    /// Restores a remembered selection so the user can adjust and re-record.
    func presentInitialRect(_ initial: NSRect) {
        rect = initial.intersection(bounds).standardized
        selectedWindowID = nil
        hoveredWindowLabel = nil
        guard rect.width > 10, rect.height > 10 else {
            rect = .zero
            return
        }
        mode = .adjusting
        selectMatchingPreset()
        selectionChanged()
    }

    /// Called when a drag begins on a different screen.
    func clearSelection() {
        mode = .idle
        rect = .zero
        selectedWindowID = nil
        hoveredWindowLabel = nil
        if captureMode == .drag { selectPresetMenuItem(id: "custom") }
        selectionChanged()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Even-odd fill leaves the selection rect genuinely unpainted (alpha 0),
        // so the content inside shows through at full brightness.
        let dim = NSBezierPath(rect: bounds)
        if rect.width > 0, rect.height > 0 {
            dim.appendRect(rect)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        guard rect.width > 0, rect.height > 0 else {
            let prompt: String?
            switch captureMode {
            case .drag: prompt = nil
            case .window: prompt = "Click a window to select it"
            case .fullScreen: prompt = "Click a display to capture it full screen"
            }
            if let prompt {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7),
                ]
                let size = prompt.size(withAttributes: attrs)
                prompt.draw(
                    at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                    withAttributes: attrs
                )
            }
            return
        }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        if mode == .adjusting, captureMode == .drag {
            for (_, handleRect) in handleRects() {
                NSColor.white.setFill()
                let path = NSBezierPath(ovalIn: handleRect)
                path.fill()
                NSColor.black.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        let sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let labelPoint = NSPoint(x: rect.minX, y: min(rect.maxY + 8, bounds.maxY - 18))
        sizeText.draw(at: labelPoint, withAttributes: attrs)

        if captureMode == .window, let hoveredWindowLabel {
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.65),
            ]
            hoveredWindowLabel.draw(
                at: NSPoint(x: rect.minX, y: max(4, rect.minY - 22)),
                withAttributes: nameAttrs
            )
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch captureMode {
        case .window:
            guard let candidate = windowCandidates.first(where: { $0.rect.contains(point) }) else { return }
            onSelectionBegan?()
            rect = candidate.rect
            selectedWindowID = candidate.windowID
            hoveredWindowLabel = candidate.label
            mode = .adjusting
            selectionChanged()
            return
        case .fullScreen:
            onSelectionBegan?()
            rect = bounds
            selectedWindowID = nil
            hoveredWindowLabel = nil
            mode = .adjusting
            selectionChanged()
            return
        case .drag:
            break
        }

        dragStart = point
        rectAtDragStart = rect

        if mode == .adjusting {
            activeHandle = handle(at: point)
            if activeHandle != .none {
                if activeHandle != .move {
                    selectPresetMenuItem(id: "custom")
                }
                return
            }
        }

        // Start a fresh selection drag.
        selectPresetMenuItem(id: "custom")
        mode = .creating
        activeHandle = .none
        rect = .zero
        onSelectionBegan?()
        selectionChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        guard captureMode == .drag else { return }
        if mode == .creating || activeHandle != .move {
            selectPresetMenuItem(id: "custom")
        }
        let point = convert(event.locationInWindow, from: nil)

        switch mode {
        case .creating:
            rect = NSRect(
                x: min(dragStart.x, point.x),
                y: min(dragStart.y, point.y),
                width: abs(point.x - dragStart.x),
                height: abs(point.y - dragStart.y)
            )
        case .adjusting:
            applyHandleDrag(to: point)
        case .idle:
            return
        }
        selectionChanged()
    }

    override func mouseUp(with event: NSEvent) {
        guard captureMode == .drag else { return }
        if mode == .creating {
            if rect.width > 10, rect.height > 10 {
                mode = .adjusting
            } else {
                mode = .idle
                rect = .zero
            }
            selectionChanged()
        }
        activeHandle = .none
    }

    override func mouseMoved(with event: NSEvent) {
        guard captureMode == .window, mode != .adjusting else { return }
        let point = convert(event.locationInWindow, from: nil)
        let candidate = windowCandidates.first { $0.rect.contains(point) }
        let newRect = candidate?.rect ?? .zero
        let newLabel = candidate?.label
        guard newRect != rect || newLabel != hoveredWindowLabel else { return }
        rect = newRect
        selectedWindowID = nil
        hoveredWindowLabel = newLabel
        selectionChanged()
    }

    private func applyHandleDrag(to point: NSPoint) {
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        var r = rectAtDragStart

        switch activeHandle {
        case .move:
            r.origin.x += dx
            r.origin.y += dy
            r.origin.x = max(0, min(r.origin.x, bounds.width - r.width))
            r.origin.y = max(0, min(r.origin.y, bounds.height - r.height))
        case .left:
            r.origin.x += dx; r.size.width -= dx
        case .right:
            r.size.width += dx
        case .bottom:
            r.origin.y += dy; r.size.height -= dy
        case .top:
            r.size.height += dy
        case .bottomLeft:
            r.origin.x += dx; r.size.width -= dx
            r.origin.y += dy; r.size.height -= dy
        case .bottomRight:
            r.size.width += dx
            r.origin.y += dy; r.size.height -= dy
        case .topLeft:
            r.origin.x += dx; r.size.width -= dx
            r.size.height += dy
        case .topRight:
            r.size.width += dx
            r.size.height += dy
        case .none:
            return
        }

        rect = r.standardized.intersection(bounds)
    }

    private func handle(at point: NSPoint) -> Handle {
        guard captureMode == .drag else { return .none }
        for (handle, handleRect) in handleRects()
        where handleRect.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point) {
            return handle
        }
        if rect.contains(point) { return .move }
        return .none
    }

    private func handleRects() -> [(Handle, NSRect)] {
        guard captureMode == .drag, rect.width > 0 else { return [] }
        let s = handleSize
        func at(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
        }
        return [
            (.bottomLeft, at(rect.minX, rect.minY)),
            (.bottom, at(rect.midX, rect.minY)),
            (.bottomRight, at(rect.maxX, rect.minY)),
            (.left, at(rect.minX, rect.midY)),
            (.right, at(rect.maxX, rect.midY)),
            (.topLeft, at(rect.minX, rect.maxY)),
            (.top, at(rect.midX, rect.maxY)),
            (.topRight, at(rect.maxX, rect.maxY)),
        ]
    }

    // MARK: - Buttons / confirm

    private func selectionChanged() {
        layoutButtons()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func layoutButtons() {
        let showButtons = mode == .adjusting && rect.width > 0
        recordButton.isHidden = !showButtons
        cancelButton.isHidden = !showButtons
        sizePresetPopup.isHidden = captureMode != .drag
        guard captureMode == .drag || showButtons else { return }

        sizePresetPopup.frame.size = NSSize(width: 250, height: 26)
        if !showButtons {
            sizePresetPopup.setFrameOrigin(NSPoint(
                x: bounds.midX - sizePresetPopup.frame.width / 2,
                y: bounds.maxY - sizePresetPopup.frame.height - 18
            ))
            return
        }

        recordButton.sizeToFit()
        cancelButton.sizeToFit()
        let spacing: CGFloat = 8
        let popupWidth = captureMode == .drag ? sizePresetPopup.frame.width + spacing : 0
        let totalWidth = popupWidth + recordButton.frame.width + spacing + cancelButton.frame.width
        let rowHeight = max(recordButton.frame.height, sizePresetPopup.frame.height)
        var y = rect.minY - rowHeight - 10
        if y < 4 {
            y = rect.maxY + 10
            if y + rowHeight > bounds.maxY - 4 {
                // No room outside either edge: use the existing centered fallback.
                y = bounds.midY - rowHeight / 2
            }
        }
        var x = rect.midX - totalWidth / 2
        x = max(4, min(x, bounds.maxX - totalWidth - 4))

        if captureMode == .drag {
            sizePresetPopup.setFrameOrigin(NSPoint(x: x, y: y))
            x += sizePresetPopup.frame.width + spacing
        }
        cancelButton.setFrameOrigin(NSPoint(x: x, y: y))
        recordButton.setFrameOrigin(NSPoint(x: x + cancelButton.frame.width + spacing, y: y))
    }

    @objc private func sizePresetChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        if id == "custom" { return }
        if id == "action:add" {
            showAddCustomSize()
            return
        }
        if id == "action:remove" {
            showRemoveCustomSize()
            return
        }
        guard let preset = allPresets.first(where: { $0.id == id }) else { return }
        applyPreset(preset)
    }

    private func applyPreset(_ preset: CaptureSizePreset) {
        guard preset.size.width <= bounds.width, preset.size.height <= bounds.height else {
            NSSound.beep()
            selectMatchingPreset()
            return
        }

        onSelectionBegan?()
        let center = rect.width > 0 && rect.height > 0
            ? NSPoint(x: rect.midX, y: rect.midY)
            : NSPoint(x: bounds.midX, y: bounds.midY)
        var origin = NSPoint(
            x: center.x - preset.size.width / 2,
            y: center.y - preset.size.height / 2
        )
        origin.x = max(0, min(origin.x, bounds.width - preset.size.width))
        origin.y = max(0, min(origin.y, bounds.height - preset.size.height))
        rect = NSRect(origin: origin, size: preset.size)
        selectedWindowID = nil
        hoveredWindowLabel = nil
        mode = .adjusting
        activeHandle = .none
        selectionChanged()
    }

    private var allPresets: [CaptureSizePreset] {
        CaptureSizePreset.builtIns + SavedCaptureSizeStore.load().map(\.preset)
    }

    private func populatePresetMenu(_ popup: NSPopUpButton, selecting selectedID: String?) {
        popup.removeAllItems()
        popup.addItem(withTitle: "Size: Custom")
        popup.lastItem?.representedObject = "custom"
        popup.menu?.addItem(.separator())

        for preset in CaptureSizePreset.builtIns {
            popup.addItem(withTitle: preset.title)
            popup.lastItem?.representedObject = preset.id
        }

        let saved = SavedCaptureSizeStore.load()
        if !saved.isEmpty {
            popup.menu?.addItem(.separator())
            let header = NSMenuItem(title: "Saved Sizes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            popup.menu?.addItem(header)
            for size in saved {
                let preset = size.preset
                popup.addItem(withTitle: preset.title)
                popup.lastItem?.representedObject = preset.id
            }
        }

        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "Add Custom Size…")
        popup.lastItem?.representedObject = "action:add"
        if !saved.isEmpty {
            popup.addItem(withTitle: "Remove Saved Size…")
            popup.lastItem?.representedObject = "action:remove"
        }

        selectPresetMenuItem(id: selectedID ?? "custom", in: popup)
    }

    private func selectPresetMenuItem(id: String, in popup: NSPopUpButton? = nil) {
        let popup = popup ?? sizePresetPopup
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == id }) {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }
    }

    private func updatePresetAvailability() {
        guard captureMode == .drag else { return }
        _ = sizePresetPopup
        for preset in allPresets {
            sizePresetPopup.itemArray.first {
                ($0.representedObject as? String) == preset.id
            }?.isEnabled = preset.size.width <= bounds.width && preset.size.height <= bounds.height
        }
    }

    private func selectMatchingPreset() {
        guard captureMode == .drag else { return }
        let match = allPresets.first {
            abs($0.size.width - rect.width) < 0.5 && abs($0.size.height - rect.height) < 0.5
        }
        selectPresetMenuItem(id: match?.id ?? "custom")
    }

    private func showAddCustomSize() {
        let initialWidth = rect.width > 10 ? Int(rect.width.rounded()) : 1280
        let initialHeight = rect.height > 10 ? Int(rect.height.rounded()) : 720
        let nameField = NSTextField(string: "Custom Size")
        let widthField = NSTextField(string: String(initialWidth))
        let heightField = NSTextField(string: String(initialHeight))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Width:"), widthField],
            [NSTextField(labelWithString: "Height:"), heightField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 92)

        let alert = NSAlert()
        alert.messageText = "Add Custom Capture Size"
        alert.informativeText = "Saved sizes appear in this menu on every recording."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save Preset")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        guard alert.runModal() == .alertFirstButtonReturn else {
            selectMatchingPreset()
            return
        }

        let width = widthField.integerValue
        let height = heightField.integerValue
        guard width > 10, height > 10 else {
            showPresetMessage("Invalid Size", "Width and height must both be greater than 10.")
            selectMatchingPreset()
            return
        }
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedCaptureSize(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? "\(width) × \(height)" : trimmedName,
            width: Double(width),
            height: Double(height)
        )
        var sizes = SavedCaptureSizeStore.load()
        sizes.append(saved)
        SavedCaptureSizeStore.save(sizes)
        populatePresetMenu(sizePresetPopup, selecting: saved.preset.id)
        updatePresetAvailability()

        if saved.width <= bounds.width, saved.height <= bounds.height {
            applyPreset(saved.preset)
        } else {
            selectMatchingPreset()
            showPresetMessage(
                "Preset Saved",
                "This size is larger than the current display, so it will be available when it fits another display."
            )
        }
    }

    private func showRemoveCustomSize() {
        let saved = SavedCaptureSizeStore.load()
        guard !saved.isEmpty else {
            selectMatchingPreset()
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: saved.map { $0.preset.title })

        let alert = NSAlert()
        alert.messageText = "Remove Saved Capture Size"
        alert.informativeText = "Built-in sizes cannot be removed."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        guard alert.runModal() == .alertFirstButtonReturn,
              saved.indices.contains(popup.indexOfSelectedItem) else {
            selectMatchingPreset()
            return
        }
        var remaining = saved
        remaining.remove(at: popup.indexOfSelectedItem)
        SavedCaptureSizeStore.save(remaining)
        populatePresetMenu(sizePresetPopup, selecting: "custom")
        updatePresetAvailability()
        selectMatchingPreset()
    }

    private func showPresetMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        alert.runModal()
    }

    @objc private func recordTapped() {
        confirmSelection()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func confirmSelection() {
        guard mode == .adjusting, rect.width > 10, rect.height > 10 else { return }
        onConfirm?(rect, selectedWindowID)
    }

    // MARK: - Keyboard / cursor

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76: // Return / keypad Enter
            confirmSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        if captureMode == .window || captureMode == .fullScreen {
            addCursorRect(bounds, cursor: .pointingHand)
            return
        }
        switch mode {
        case .adjusting:
            addCursorRect(bounds, cursor: .crosshair)
            addCursorRect(rect, cursor: .openHand)
            for (handle, handleRect) in handleRects() {
                let hitRect = handleRect.insetBy(dx: -hitTolerance / 2, dy: -hitTolerance / 2)
                switch handle {
                case .left, .right:
                    addCursorRect(hitRect, cursor: .resizeLeftRight)
                case .top, .bottom:
                    addCursorRect(hitRect, cursor: .resizeUpDown)
                default:
                    addCursorRect(hitRect, cursor: .crosshair)
                }
            }
        default:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}
