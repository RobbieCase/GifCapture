import AppKit
import Carbon

struct KeyboardShortcut: Equatable {
    let keyCode: UInt32
    let modifierRawValue: UInt
    let keyName: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers
            .intersection([.command, .control, .option, .shift])
            .rawValue
        self.keyName = keyName
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection([.command, .control, .option, .shift])
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyName
    }

    static let defaultStartRecording = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_G), modifiers: [.control, .command], keyName: "G"
    )
    static let defaultOpenLibrary = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_L), modifiers: [.control, .command], keyName: "L"
    )
    static let defaultStopRecording = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .command], keyName: "S"
    )

    static func load(from defaults: UserDefaults, prefix: String, fallback: KeyboardShortcut) -> KeyboardShortcut {
        guard defaults.object(forKey: "\(prefix).keyCode") != nil,
              defaults.object(forKey: "\(prefix).modifiers") != nil,
              let keyName = defaults.string(forKey: "\(prefix).keyName"),
              !keyName.isEmpty else { return fallback }
        return KeyboardShortcut(
            keyCode: UInt32(defaults.integer(forKey: "\(prefix).keyCode")),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "\(prefix).modifiers"))),
            keyName: keyName
        )
    }

    func save(to defaults: UserDefaults, prefix: String) {
        defaults.set(Int(keyCode), forKey: "\(prefix).keyCode")
        defaults.set(Int(modifierRawValue), forKey: "\(prefix).modifiers")
        defaults.set(keyName, forKey: "\(prefix).keyName")
    }
}

enum RecordingModifier: String, CaseIterable {
    case control
    case option
    case shift
    case command

    var displayName: String {
        switch self {
        case .control: return "Control (⌃)"
        case .option: return "Option (⌥)"
        case .shift: return "Shift (⇧)"
        case .command: return "Command (⌘)"
        }
    }

    var shortName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        }
    }
}

extension Notification.Name {
    static let gifCaptureSettingsChanged = Notification.Name("GifCaptureSettingsChanged")
    static let shortcutCaptureBegan = Notification.Name("GifCaptureShortcutCaptureBegan")
    static let shortcutCaptureEnded = Notification.Name("GifCaptureShortcutCaptureEnded")
}

final class GlobalHotKeyManager {
    private static let signature: OSType = 0x47494643 // "GIFC"

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var releaseActions: [UInt32: () -> Void] = [:]
    private var generation = 0

    init() {
        var eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        ), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                guard hotKeyID.signature == GlobalHotKeyManager.signature, manager.actions[hotKeyID.id] != nil else {
                    return OSStatus(eventNotHandledErr)
                }
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                let generation = manager.generation
                DispatchQueue.main.async {
                    guard manager.generation == generation else { return }
                    if released { manager.releaseActions[hotKeyID.id]?() }
                    else { manager.actions[hotKeyID.id]?() }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    @discardableResult
    func register(id: UInt32, shortcut: KeyboardShortcut, action: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> Bool {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return false }
        actions[id] = action
        releaseActions[id] = onRelease
        hotKeyRefs.append(hotKeyRef)
        return true
    }

    func clear() {
        generation += 1
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        releaseActions.removeAll()
    }

    deinit {
        clear()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcut = .defaultStartRecording {
        didSet { if monitor == nil { title = shortcut.displayName } }
    }
    var onBeginCapture: (() -> Void)?
    var onChange: ((KeyboardShortcut) -> Void)?

    private var monitor: Any?

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginCapture)
        title = shortcut.displayName
        toolTip = "Click, then type a shortcut"
    }

    @objc private func beginCapture() {
        cancelCapture()
        onBeginCapture?()
        NotificationCenter.default.post(name: .shortcutCaptureBegan, object: self)
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelCapture()
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  let keyName = Self.keyName(for: event) else {
                NSSound.beep()
                return nil
            }

            let newShortcut = KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                keyName: keyName
            )
            self.finishCapture()
            self.shortcut = newShortcut
            self.onChange?(newShortcut)
            return nil
        }
    }

    func cancelCapture() {
        guard monitor != nil else { return }
        finishCapture()
        title = shortcut.displayName
    }

    private func finishCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutCaptureEnded, object: self)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    static func keyName(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape: return "Esc"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            guard let characters = event.charactersIgnoringModifiers?.uppercased(),
                  !characters.isEmpty else { return nil }
            return characters
        }
    }
}
