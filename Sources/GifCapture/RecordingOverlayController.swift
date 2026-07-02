import AppKit

/// Shown while recording: dims everything around the capture box and anchors a
/// timer + Stop button to the top of the box. Both windows are excluded from the
/// screen capture itself (see `captureExcludedWindowIDs`), so neither the dimming
/// nor the button appears in the GIF.
final class RecordingOverlayController: NSObject {
    private var dimWindow: NSWindow?
    private var panel: NSPanel?
    private var timer: Timer?
    private var startTime = Date()
    private weak var timeLabel: NSTextField?

    private let screen: NSScreen
    private let topLeftRect: CGRect
    private let onStop: () -> Void

    init(screen: NSScreen, topLeftRect: CGRect, onStop: @escaping () -> Void) {
        self.screen = screen
        self.topLeftRect = topLeftRect
        self.onStop = onStop
    }

    /// Window IDs the recorder must exclude so the overlay isn't captured.
    var captureExcludedWindowIDs: [CGWindowID] {
        [dimWindow, panel].compactMap { $0 }.map { CGWindowID($0.windowNumber) }
    }

    func show() {
        let localRect = NSRect(
            x: topLeftRect.minX,
            y: screen.frame.height - topLeftRect.minY - topLeftRect.height,
            width: topLeftRect.width,
            height: topLeftRect.height
        )

        showDimWindow(cutout: localRect)
        showControlPanel(above: localRect)

        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func showDimWindow(cutout: NSRect) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true // clicks pass through to the apps being recorded
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RecordingDimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.cutout = cutout
        window.contentView = view
        window.orderFrontRegardless()
        dimWindow = window
    }

    private func showControlPanel(above rect: NSRect) {
        let width: CGFloat = 190
        let height: CGFloat = 38
        let gap: CGFloat = 10

        var x = rect.midX - width / 2
        x = max(8, min(x, screen.frame.width - width - 8))
        var y = rect.maxY + gap
        if y + height > screen.frame.height - 4 {
            y = rect.maxY - height - gap // no room above: tuck inside the top edge
        }
        let origin = NSPoint(x: screen.frame.origin.x + x, y: screen.frame.origin.y + y)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 9

        let dot = NSView(frame: NSRect(x: 14, y: height / 2 - 5, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        container.addSubview(dot)

        let label = NSTextField(labelWithString: "00:00")
        label.frame = NSRect(x: 32, y: height / 2 - 10, width: 60, height: 20)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        container.addSubview(label)
        timeLabel = label

        let button = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        button.frame = NSRect(x: width - 74, y: height / 2 - 12, width: 60, height: 24)
        button.bezelStyle = .rounded
        container.addSubview(button)

        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(startTime))
        timeLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopTapped() {
        onStop()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        dimWindow?.orderOut(nil)
        dimWindow = nil
    }
}

private final class RecordingDimView: NSView {
    var cutout: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        // Even-odd fill leaves the capture area genuinely unpainted (alpha 0).
        let dim = NSBezierPath(rect: bounds)
        dim.appendRect(cutout)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: cutout)
        border.lineWidth = 2
        border.stroke()
    }
}
