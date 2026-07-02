import AppKit

final class SelectionOverlayView: NSView {
    var screen: NSScreen?
    /// Fires with the confirmed rect in view coordinates (bottom-left origin).
    var onConfirm: ((CGRect) -> Void)?
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

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Restores a remembered selection so the user can adjust and re-record.
    func presentInitialRect(_ initial: NSRect) {
        rect = initial.intersection(bounds).standardized
        guard rect.width > 10, rect.height > 10 else {
            rect = .zero
            return
        }
        mode = .adjusting
        selectionChanged()
    }

    /// Called when a drag begins on a different screen.
    func clearSelection() {
        mode = .idle
        rect = .zero
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

        guard rect.width > 0, rect.height > 0 else { return }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        if mode == .adjusting {
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
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        rectAtDragStart = rect

        if mode == .adjusting {
            activeHandle = handle(at: point)
            if activeHandle != .none { return }
        }

        // Start a fresh selection drag.
        mode = .creating
        activeHandle = .none
        rect = .zero
        onSelectionBegan?()
        selectionChanged()
    }

    override func mouseDragged(with event: NSEvent) {
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
        for (handle, handleRect) in handleRects()
        where handleRect.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point) {
            return handle
        }
        if rect.contains(point) { return .move }
        return .none
    }

    private func handleRects() -> [(Handle, NSRect)] {
        guard rect.width > 0 else { return [] }
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
        guard showButtons else { return }

        recordButton.sizeToFit()
        cancelButton.sizeToFit()
        let spacing: CGFloat = 8
        let totalWidth = recordButton.frame.width + spacing + cancelButton.frame.width
        let buttonHeight = recordButton.frame.height
        var y = rect.minY - buttonHeight - 10
        if y < 4 { y = min(rect.maxY + 10, bounds.maxY - buttonHeight - 4) }
        var x = rect.midX - totalWidth / 2
        x = max(4, min(x, bounds.maxX - totalWidth - 4))

        cancelButton.setFrameOrigin(NSPoint(x: x, y: y))
        recordButton.setFrameOrigin(NSPoint(x: x + cancelButton.frame.width + spacing, y: y))
    }

    @objc private func recordTapped() {
        confirmSelection()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func confirmSelection() {
        guard mode == .adjusting, rect.width > 10, rect.height > 10 else { return }
        onConfirm?(rect)
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
