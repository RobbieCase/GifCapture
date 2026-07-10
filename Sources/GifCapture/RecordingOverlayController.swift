import AppKit

/// Shown while recording: dims everything around the capture box and anchors a
/// timer + Zoom/Pen/Stop controls to the top of the box, plus a pen tool
/// palette beside it. The dim layer and panels are excluded from the screen
/// capture (see `captureExcludedWindowIDs`); the pen drawing window
/// intentionally is NOT, so ink shows up in the GIF.
final class RecordingOverlayController: NSObject {
    private var dimWindow: NSWindow?
    private weak var dimView: RecordingDimView?
    private var panel: NSPanel?
    private var toolPanel: NSPanel?
    private var drawWindow: NSWindow?
    private var drawView: PenDrawingView?

    private var timer: Timer?
    private var modifierTimer: Timer?
    private var indicatorTimer: Timer?
    private var startTime = Date()
    private weak var timeLabel: NSTextField?
    private weak var zoomButton: NSButton?
    private weak var penButton: NSButton?
    private var swatchButtons: [NSButton] = []

    private let screen: NSScreen
    private let topLeftRect: CGRect
    private let onStop: () -> Void

    /// Fires when the effective zoom state (button OR Control key) changes.
    var onZoomChange: ((Bool) -> Void)?

    private var zoomSticky = false
    private var penSticky = false
    private var lastZoom = false
    private var lastPen = false
    private var indicatorZoom: CGFloat = 1.0

    init(screen: NSScreen, topLeftRect: CGRect, onStop: @escaping () -> Void) {
        self.screen = screen
        self.topLeftRect = topLeftRect
        self.onStop = onStop
    }

    /// Window IDs the recorder must exclude so the chrome isn't captured.
    /// The pen window is deliberately absent: ink should be recorded.
    var captureExcludedWindowIDs: [CGWindowID] {
        [dimWindow, panel, toolPanel].compactMap { $0 }.map { CGWindowID($0.windowNumber) }
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
        showToolPanel(beside: localRect)

        startTime = Date()
        timer = scheduled(1) { [weak self] in self?.tick() }
        modifierTimer = scheduled(0.1) { [weak self] in self?.pollModifiers() }
        indicatorTimer = scheduled(1.0 / 30.0) { [weak self] in self?.updateZoomIndicator() }
    }

    /// Timers added to .common so they keep firing during mouse-drag tracking.
    private func scheduled(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
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
        dimView = view
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

        let panel = makePanel(frame: NSRect(origin: origin, size: NSSize(width: width, height: height)))
        let container = panel.contentView!

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

        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func showToolPanel(beside rect: NSRect) {
        let width: CGFloat = 172
        let height: CGFloat = 118
        let gap: CGFloat = 10

        // Prefer the right side of the capture box, then the left, then inside.
        var x = rect.maxX + gap
        if x + width > screen.frame.width - 4 {
            x = rect.minX - width - gap
        }
        if x < 4 {
            x = min(rect.maxX - width - gap, screen.frame.width - width - 4)
        }
        var y = rect.maxY - height
        y = max(4, min(y, screen.frame.height - height - 4))
        let origin = NSPoint(x: screen.frame.origin.x + x, y: screen.frame.origin.y + y)

        let panel = makePanel(frame: NSRect(origin: origin, size: NSSize(width: width, height: height)))
        let container = panel.contentView!

        // Tool picker
        let tools = NSSegmentedControl(
            images: [
                symbol("scribble", "Free draw"),
                symbol("line.diagonal", "Straight line"),
                symbol("rectangle", "Rectangle"),
                symbol("circle", "Ellipse"),
            ],
            trackingMode: .selectOne,
            target: self, action: #selector(toolChanged(_:))
        )
        tools.selectedSegment = 0
        tools.frame = NSRect(x: 10, y: height - 34, width: width - 20, height: 24)
        container.addSubview(tools)

        // Color swatches
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .white, .black]
        let swatchSize: CGFloat = 15
        let spacing = (width - 20 - swatchSize * CGFloat(colors.count)) / CGFloat(colors.count - 1)
        swatchButtons = []
        for (index, color) in colors.enumerated() {
            let button = NSButton(frame: NSRect(
                x: 10 + CGFloat(index) * (swatchSize + spacing),
                y: height - 62, width: swatchSize, height: swatchSize
            ))
            button.isBordered = false
            button.title = ""
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = swatchSize / 2
            button.layer?.borderColor = NSColor.white.cgColor
            button.layer?.borderWidth = index == 0 ? 2 : 0
            button.tag = index
            button.target = self
            button.action = #selector(colorPicked(_:))
            container.addSubview(button)
            swatchButtons.append(button)
        }
        drawView?.strokeColor = colors[0]

        // Fade picker
        let fadeLabel = NSTextField(labelWithString: "Fade after")
        fadeLabel.textColor = .white
        fadeLabel.font = .systemFont(ofSize: 11)
        fadeLabel.frame = NSRect(x: 10, y: height - 92, width: 62, height: 16)
        container.addSubview(fadeLabel)

        let fade = NSPopUpButton(frame: NSRect(x: 74, y: height - 97, width: width - 84, height: 24), pullsDown: false)
        fade.addItems(withTitles: ["1 s", "3 s", "5 s", "10 s", "Never"])
        fade.selectItem(at: 1)
        fade.target = self
        fade.action = #selector(fadeChanged(_:))
        container.addSubview(fade)

        panel.orderFrontRegardless()
        toolPanel = panel
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Controls sit on a dark backdrop; without this they render dark-on-dark.
        panel.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        container.layer?.cornerRadius = 9
        panel.contentView = container
        return panel
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
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

    /// Mirrors the recorder's animated zoom so the on-screen viewport indicator
    /// matches what's being written to the video.
    private func updateZoomIndicator() {
        let target: CGFloat = lastZoom ? 2.0 : 1.0
        if abs(indicatorZoom - target) > 0.004 {
            indicatorZoom += (target - indicatorZoom) * 0.16
        } else {
            indicatorZoom = target
        }
        guard let dimView else { return }
        guard indicatorZoom > 1.01 else {
            if dimView.zoomViewport != nil { dimView.zoomViewport = nil }
            return
        }
        let cutout = dimView.cutout
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - screen.frame.origin.x
        let localY = mouse.y - screen.frame.origin.y
        let w = cutout.width / indicatorZoom
        let h = cutout.height / indicatorZoom
        let x = min(max(localX - w / 2, cutout.minX), cutout.maxX - w)
        let y = min(max(localY - h / 2, cutout.minY), cutout.maxY - h)
        dimView.zoomViewport = NSRect(x: x, y: y, width: w, height: h)
    }

    @objc private func zoomToggled() {
        zoomSticky = zoomButton?.state == .on
        pollModifiers()
    }

    @objc private func penToggled() {
        penSticky = penButton?.state == .on
        pollModifiers()
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let tools: [PenDrawingView.Tool] = [.free, .line, .rect, .ellipse]
        drawView?.tool = tools[max(0, min(sender.selectedSegment, tools.count - 1))]
    }

    @objc private func colorPicked(_ sender: NSButton) {
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .white, .black]
        guard colors.indices.contains(sender.tag) else { return }
        drawView?.strokeColor = colors[sender.tag]
        for button in swatchButtons {
            button.layer?.borderWidth = button == sender ? 2 : 0
        }
    }

    @objc private func fadeChanged(_ sender: NSPopUpButton) {
        let values: [Double] = [1, 3, 5, 10, .infinity]
        guard values.indices.contains(sender.indexOfSelectedItem) else { return }
        drawView?.fadeAfter = values[sender.indexOfSelectedItem]
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(startTime))
        timeLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopTapped() {
        onStop()
    }

    func close() {
        [timer, modifierTimer, indicatorTimer].forEach { $0?.invalidate() }
        timer = nil
        modifierTimer = nil
        indicatorTimer = nil
        [panel, toolPanel, drawWindow, dimWindow].forEach { $0?.orderOut(nil) }
        panel = nil
        toolPanel = nil
        drawWindow = nil
        drawView = nil
        dimWindow = nil
    }
}

private final class RecordingDimView: NSView {
    var cutout: NSRect = .zero
    /// Region currently visible in the zoomed recording; shown live so the
    /// user can see what the GIF will contain. Not captured (this window is
    /// excluded from the recording).
    var zoomViewport: NSRect? {
        didSet { if zoomViewport != oldValue { needsDisplay = true } }
    }

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

        if let viewport = zoomViewport {
            // Shade the part of the capture box that's outside the zoom viewport.
            let shade = NSBezierPath(rect: cutout)
            shade.appendRect(viewport)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            shade.fill()

            NSColor.white.setStroke()
            let viewportBorder = NSBezierPath(rect: viewport)
            viewportBorder.lineWidth = 2
            viewportBorder.stroke()
        }
    }
}

/// Transparent canvas over the capture area. Strokes render in the recording
/// (this window is not capture-excluded) and fade out after each stroke is
/// finished, per the tool panel's fade setting.
final class PenDrawingView: NSView {
    enum Tool { case free, line, rect, ellipse }

    var tool: Tool = .free
    var strokeColor: NSColor = .systemRed
    var fadeAfter: Double = 3
    var penActive = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private struct Stroke {
        var path: NSBezierPath
        let color: NSColor
        let fadeAfter: Double
        var finishedAt: Date?
    }

    private var strokes: [Stroke] = []
    private var anchor: NSPoint = .zero
    private var fadeTimer: Timer?
    private let fadeSeconds = 1.0

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        let path = newPath()
        if tool == .free { path.move(to: anchor) }
        strokes.append(Stroke(path: path, color: strokeColor, fadeAfter: fadeAfter, finishedAt: nil))
        ensureFadeTimer()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .free:
            strokes[strokes.count - 1].path.line(to: point)
        case .line:
            let path = newPath()
            path.move(to: anchor)
            path.line(to: point)
            strokes[strokes.count - 1].path = path
        case .rect:
            strokes[strokes.count - 1].path = shapePath { NSBezierPath(rect: rect(to: point)) }
        case .ellipse:
            strokes[strokes.count - 1].path = shapePath { NSBezierPath(ovalIn: rect(to: point)) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].finishedAt = Date()
    }

    private func newPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private func shapePath(_ make: () -> NSBezierPath) -> NSBezierPath {
        let path = make()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private func rect(to point: NSPoint) -> NSRect {
        NSRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for stroke in strokes {
            let alpha: CGFloat
            if let finished = stroke.finishedAt, stroke.fadeAfter.isFinite {
                let age = now.timeIntervalSince(finished)
                alpha = age <= stroke.fadeAfter
                    ? 1
                    : max(0, 1 - CGFloat((age - stroke.fadeAfter) / fadeSeconds))
            } else {
                alpha = 1
            }
            guard alpha > 0 else { continue }
            stroke.color.withAlphaComponent(alpha).setStroke()
            stroke.path.stroke()
        }
    }

    private func ensureFadeTimer() {
        guard fadeTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.strokes.removeAll { stroke in
                guard let finished = stroke.finishedAt, stroke.fadeAfter.isFinite else { return false }
                return now.timeIntervalSince(finished) > stroke.fadeAfter + self.fadeSeconds
            }
            if self.strokes.isEmpty {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
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
