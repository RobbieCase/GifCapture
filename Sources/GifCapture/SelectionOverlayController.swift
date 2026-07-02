import AppKit
import ScreenCaptureKit

struct SelectionResult {
    /// Capture rectangle in points, top-left origin, relative to the target display —
    /// matches the coordinate space SCStreamConfiguration.sourceRect expects.
    let rect: CGRect
    let display: SCDisplay
    let screen: NSScreen
}

/// Borderless windows refuse key status by default; we need it for Return/Esc handling.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    private let completion: (SelectionResult?) -> Void
    private var monitor: Any?
    private var finished = false

    private static let savedRectKey = "lastSelection.rect"
    private static let savedScreenKey = "lastSelection.displayID"

    init(completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
    }

    func begin() {
        var views: [SelectionOverlayView] = []
        var restoredWindow: NSWindow?

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen = screen
            view.onConfirm = { [weak self] viewRect in
                self?.finish(viewRect: viewRect, screen: screen)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            views.append(view)

            if let saved = Self.savedSelection(for: screen) {
                view.presentInitialRect(saved)
                restoredWindow = window
            }
        }

        // A drag on one screen clears any selection shown on the others.
        for view in views {
            view.onSelectionBegan = { [weak view] in
                for other in views where other !== view {
                    other.clearSelection()
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        (restoredWindow ?? windows.first)?.makeKey()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            return event
        }
    }

    private func finish(viewRect: CGRect, screen: NSScreen) {
        guard viewRect.width > 10, viewRect.height > 10 else {
            cancel()
            return
        }
        Self.saveSelection(viewRect, for: screen)
        closeAll()

        // AppKit views use bottom-left origin; ScreenCaptureKit's sourceRect uses top-left origin.
        let rect = CGRect(
            x: viewRect.minX,
            y: screen.frame.height - viewRect.maxY,
            width: viewRect.width,
            height: viewRect.height
        )

        Task {
            let display = await Self.matchDisplay(for: screen)
            await MainActor.run {
                guard !self.finished else { return }
                self.finished = true
                guard let display else {
                    self.completion(nil)
                    return
                }
                self.completion(SelectionResult(rect: rect, display: display, screen: screen))
            }
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        closeAll()
        completion(nil)
    }

    private func closeAll() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - Selection memory

    private static func saveSelection(_ rect: CGRect, for screen: NSScreen) {
        guard let id = displayID(of: screen) else { return }
        let d = UserDefaults.standard
        d.set(NSStringFromRect(rect), forKey: savedRectKey)
        d.set(Int(id), forKey: savedScreenKey)
    }

    private static func savedSelection(for screen: NSScreen) -> NSRect? {
        let d = UserDefaults.standard
        guard let rectString = d.string(forKey: savedRectKey),
              let id = displayID(of: screen),
              d.integer(forKey: savedScreenKey) == Int(id) else { return nil }
        let rect = NSRectFromString(rectString)
        guard rect.width > 10, rect.height > 10 else { return nil }
        return rect
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func matchDisplay(for screen: NSScreen) async -> SCDisplay? {
        guard let displayID = displayID(of: screen) else { return nil }
        guard let content = try? await SCShareableContent.current else { return nil }
        return content.displays.first { $0.displayID == displayID }
    }
}
