import AppKit

/// A short, cancellable countdown shown after region selection and before the
/// capture stream starts. The window disappears before recording begins.
final class CountdownOverlayController {
    private var window: NSWindow?
    private weak var label: NSTextField?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var value = 3
    private var finished = false
    private let completion: (Bool) -> Void

    init(screen: NSScreen, topLeftRect: CGRect, completion: @escaping (Bool) -> Void) {
        self.completion = completion

        let localRect = NSRect(
            x: topLeftRect.minX,
            y: screen.frame.height - topLeftRect.minY - topLeftRect.height,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        let size = NSSize(width: 112, height: 112)
        let origin = NSPoint(
            x: screen.frame.origin.x + localRect.midX - size.width / 2,
            y: screen.frame.origin.y + localRect.midY - size.height / 2
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 22

        let label = NSTextField(labelWithString: "3")
        label.frame = container.bounds
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        label.textColor = .white
        label.backgroundColor = .clear
        container.addSubview(label)
        window.contentView = container

        self.window = window
        self.label = label
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            self?.cancel()
            return nil
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        finish(completed: false)
    }

    private func advance() {
        value -= 1
        if value == 0 {
            finish(completed: true)
        } else {
            label?.stringValue = String(value)
        }
    }

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
        completion(completed)
    }

    deinit {
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
