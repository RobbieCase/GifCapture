import AppKit

/// Shown while recording: dims everything around the capture box and anchors a
/// timer + Zoom/Pen/Stop controls to the top of the box. The dim layer and the
/// control panel are excluded from the screen capture (see
/// `captureExcludedWindowIDs`); the pen drawing window intentionally is NOT,
/// so ink shows up in the GIF.
final class RecordingOverlayController: NSObject {
    private var dimWindow: NSWindow?
    private var panel: NSPanel?
    private var drawWindow: NSWindow?
    private var drawView: PenDrawingView?
    private var timer: Timer?
    private var modifierTimer: Timer?
    private var startTime = Date()
    private weak var timeLabel: NSTextField?
    private weak var zoomButton: NSButton?
    private weak var penButton: NSButton?

    private let screen: NSScreen
    private let topLeftRect: CGRect
    private let onStop: () -> Void

    /// Fires when the effective zoom state (button OR Control key) changes.
    var onZoomChange: ((Bool) -> Void)?

    private var zoomSticky = false
    private var penSticky = false
    private var lastZoom = false
    private var lastPen = false

    init(screen: NSScreen, topLeftRect: CGRect, onStop: @escaping () -> Void) {
        self.screen = screen
        self.topLeftRect = topLeftRect
        self.onStop = onStop
    }

    /// Window IDs the recorder must exclude so the chrome isn't captured.
    /// The pen window is deliberately absent: ink should be recorded.
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
        showDrawWindow(over: localRect)
        showControlPanel(above: localRect)

        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollModifiers()
        }
    }

    // MARK: - Windows

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

    private func showDrawWindow(over localRect: NSRect) {
        let globalFrame = NSRect(
            x: screen.frame.origin.x + localRect.minX,
            y: screen.frame.origin.y + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        let window = NSWindow(
            contentRect: globalFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // until the pen is active
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PenDrawingView(frame: NSRect(origin: .zero, size: globalFrame.size))
        window.contentView = view
        window.orderFrontRegardless()
        drawWindow = window
        drawView = view
    }

    private func showControlPanel(above rect: NSRect) {
        let width: CGFloat = 330
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

        let dot = NSView(frame: NSRect(x: 12, y: height / 2 - 5, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        container.addSubview(dot)

        let label = NSTextField(labelWithString: "00:00")
        label.frame = NSRect(x: 28, y: height / 2 - 10, width: 46, height: 20)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        container.addSubview(label)
        timeLabel = label

        let zoom = NSButton(title: "Zoom", target: self, action: #selector(zoomToggled))
        zoom.setButtonType(.pushOnPushOff)
        zoom.bezelStyle = .rounded
        zoom.frame = NSRect(x: 78, y: height / 2 - 12, width: 64, height: 24)
        zoom.toolTip = "Zoom toward the cursor (or hold Control)"
        container.addSubview(zoom)
        zoomButton = zoom

        let pen = NSButton(title: "Pen", target: self, action: #selector(penToggled))
        pen.setButtonType(.pushOnPushOff)
        pen.bezelStyle = .rounded
        pen.frame = NSRect(x: 146, y: height / 2 - 12, width: 56, height: 24)
        pen.toolTip = "Draw on the recording (or hold Shift and drag)"
        container.addSubview(pen)
        penButton = pen

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stop.frame = NSRect(x: width - 70, y: height / 2 - 12, width: 60, height: 24)
        stop.bezelStyle = .rounded
        container.addSubview(stop)

        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: - State

    private func pollModifiers() {
        let flags = NSEvent.modifierFlags
        let zoom = zoomSticky || flags.contains(.control)
        let pen = penSticky || flags.contains(.shift)

        if zoom != lastZoom {
            lastZoom = zoom
            zoomButton?.state = zoom ? .on : .off
            onZoomChange?(zoom)
        }
        if pen != lastPen {
            lastPen = pen
            penButton?.state = pen ? .on : .off
            drawWindow?.ignoresMouseEvents = !pen
            drawView?.penActive = pen
        }
    }

    @objc private func zoomToggled() {
        zoomSticky = zoomButton?.state == .on
        pollModifiers()
    }

    @objc private func penToggled() {
        penSticky = penButton?.state == .on
        pollModifiers()
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
        modifierTimer?.invalidate()
        modifierTimer = nil
        panel?.orderOut(nil)
        panel = nil
        drawWindow?.orderOut(nil)
        drawWindow = nil
        drawView = nil
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

/// Transparent canvas over the capture area. Strokes render in the recording
/// (this window is not capture-excluded) and fade out a few seconds after each
/// stroke is finished.
final class PenDrawingView: NSView {
    var penActive = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private struct Stroke {
        let path: NSBezierPath
        var finishedAt: Date?
    }

    private var strokes: [Stroke] = []
    private var fadeTimer: Timer?

    private let holdSeconds = 2.5
    private let fadeSeconds = 1.0

    override func mouseDown(with event: NSEvent) {
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: convert(event.locationInWindow, from: nil))
        strokes.append(Stroke(path: path, finishedAt: nil))
        ensureFadeTimer()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].path.line(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].finishedAt = Date()
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for stroke in strokes {
            let alpha: CGFloat
            if let finished = stroke.finishedAt {
                let age = now.timeIntervalSince(finished)
                alpha = age <= holdSeconds ? 1 : max(0, 1 - CGFloat((age - holdSeconds) / fadeSeconds))
            } else {
                alpha = 1
            }
            guard alpha > 0 else { continue }
            NSColor.systemRed.withAlphaComponent(alpha).setStroke()
            stroke.path.stroke()
        }
    }

    private func ensureFadeTimer() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.strokes.removeAll { stroke in
                guard let finished = stroke.finishedAt else { return false }
                return now.timeIntervalSince(finished) > self.holdSeconds + self.fadeSeconds
            }
            if self.strokes.isEmpty {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    override func resetCursorRects() {
        if penActive {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }
}
