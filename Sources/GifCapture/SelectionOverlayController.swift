import AppKit
import CoreGraphics
import ScreenCaptureKit

struct SelectionResult {
    /// Capture rectangle in points, top-left origin, relative to the target display —
    /// matches the coordinate space SCStreamConfiguration.sourceRect expects.
    let rect: CGRect
    let display: SCDisplay
    let screen: NSScreen
    let captureMode: CaptureMode
    let windowID: CGWindowID?
}

struct WindowSelectionCandidate {
    let windowID: CGWindowID
    let rect: NSRect
    let label: String
}

/// Shared window geometry helpers. Core Graphics window bounds omit the drop
/// shadow; the small inset also removes the outer framing pixels.
enum WindowCaptureGeometry {
    static func captureBounds(for windowID: CGWindowID) -> CGRect? {
        guard let info = windowInfo(options: [.optionIncludingWindow], relativeTo: windowID).first,
              let frame = frame(from: info) else { return nil }
        let cropped = frame.insetBy(dx: 1, dy: 1)
        return cropped.width > 10 && cropped.height > 10 ? cropped : nil
    }

    static func selectionCandidates(for screen: NSScreen) -> [WindowSelectionCandidate] {
        guard let displayID = displayID(of: screen) else { return [] }
        let displayBounds = CGDisplayBounds(displayID)
        let ownPID = getpid()

        return windowInfo(options: [.optionOnScreenOnly, .excludeDesktopElements])
            .compactMap { info in
                guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                      (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                      let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                      let rawFrame = frame(from: info),
                      rawFrame.width > 80, rawFrame.height > 40 else { return nil }

                let captureFrame = rawFrame.insetBy(dx: 1, dy: 1)
                let clipped = captureFrame.intersection(displayBounds)
                guard !clipped.isNull, clipped.width > 10, clipped.height > 10 else { return nil }

                let localRect = NSRect(
                    x: clipped.minX - displayBounds.minX,
                    y: screen.frame.height - (clipped.minY - displayBounds.minY) - clipped.height,
                    width: clipped.width,
                    height: clipped.height
                )
                let owner = info[kCGWindowOwnerName as String] as? String ?? "Window"
                let title = info[kCGWindowName as String] as? String
                let label = title.flatMap { $0.isEmpty ? nil : "\(owner) — \($0)" } ?? owner
                return WindowSelectionCandidate(
                    windowID: CGWindowID(windowNumber.uint32Value),
                    rect: localRect,
                    label: label
                )
            }
    }

    static func displayRelativeRect(
        for windowID: CGWindowID,
        displayID: CGDirectDisplayID,
        fixedSize: CGSize? = nil
    ) -> CGRect? {
        guard let bounds = captureBounds(for: windowID) else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        let size = fixedSize ?? bounds.size
        var rect = CGRect(
            x: bounds.minX - displayBounds.minX,
            y: bounds.minY - displayBounds.minY,
            width: size.width,
            height: size.height
        )
        guard rect.intersects(CGRect(origin: .zero, size: displayBounds.size)) else { return nil }
        rect.origin.x = max(0, min(rect.origin.x, displayBounds.width - rect.width))
        rect.origin.y = max(0, min(rect.origin.y, displayBounds.height - rect.height))
        return rect
    }

    private static func windowInfo(
        options: CGWindowListOption,
        relativeTo windowID: CGWindowID = kCGNullWindowID
    ) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] ?? []
    }

    private static func frame(from info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

/// Borderless windows refuse key status by default; we need it for Return/Esc handling.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayController {
    private var windows: [NSWindow] = []
    private let captureMode: CaptureMode
    private let completion: (SelectionResult?) -> Void
    private var monitor: Any?
    private var finished = false

    init(captureMode: CaptureMode, completion: @escaping (SelectionResult?) -> Void) {
        self.captureMode = captureMode
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
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen = screen
            view.captureMode = captureMode
            if captureMode == .window {
                view.windowCandidates = WindowCaptureGeometry.selectionCandidates(for: screen)
            }
            view.onConfirm = { [weak self] viewRect, windowID in
                self?.finish(viewRect: viewRect, screen: screen, windowID: windowID)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            views.append(view)

            if captureMode == .drag {
                view.presentInitialRect(Self.defaultDragSelection(in: view.bounds))
                restoredWindow = window
            }
        }

        // A selection on one screen clears any selection shown on the others.
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

    private func finish(viewRect: CGRect, screen: NSScreen, windowID: CGWindowID?) {
        guard viewRect.width > 10, viewRect.height > 10 else {
            cancel()
            return
        }
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
                self.completion(SelectionResult(
                    rect: rect,
                    display: display,
                    screen: screen,
                    captureMode: self.captureMode,
                    windowID: windowID
                ))
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

    static func defaultDragSelection(in bounds: NSRect) -> NSRect {
        let target = NSSize(width: 1280, height: 720)
        let scale = min(1, bounds.width / target.width, bounds.height / target.height)
        let size = NSSize(width: target.width * scale, height: target.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func matchDisplay(for screen: NSScreen) async -> SCDisplay? {
        guard let displayID = WindowCaptureGeometry.displayID(of: screen) else { return nil }
        guard let content = try? await SCShareableContent.current else { return nil }
        return content.displays.first { $0.displayID == displayID }
    }
}
