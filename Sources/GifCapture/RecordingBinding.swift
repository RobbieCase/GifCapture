import AppKit

/// A hold binding can be a modifier chord alone or an ordinary key with an
/// optional modifier chord. Store physical key codes, not typed characters.
struct RecordingBinding: Codable, Hashable {
    let keyCode: UInt32?
    let modifierRawValue: UInt
    let keyName: String

    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(keyCode: UInt32? = nil, modifiers: NSEvent.ModifierFlags, keyName: String = "") {
        self.keyCode = keyCode
        modifierRawValue = modifiers.intersection(Self.modifierMask).rawValue
        self.keyName = keyName
    }

    init(_ modifier: RecordingModifier) {
        self.init(modifiers: modifier.eventFlag)
    }

    init(_ shortcut: KeyboardShortcut) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, keyName: shortcut.keyName)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    var shortcut: KeyboardShortcut? {
        keyCode.map { KeyboardShortcut(keyCode: $0, modifiers: modifiers, keyName: keyName) }
    }

    var displayName: String {
        if let shortcut { return shortcut.displayName }
        return RecordingModifier.allCases.filter { modifiers.contains($0.eventFlag) }
            .map(\.shortName).joined(separator: " + ")
    }

    func matches(flags: NSEvent.ModifierFlags, keyHeld: Bool = false) -> Bool {
        let flags = flags.intersection(Self.modifierMask)
        if keyCode != nil { return keyHeld && flags == modifiers }
        return !modifiers.isEmpty && flags.isSuperset(of: modifiers)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifierRawValue == rhs.modifierRawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifierRawValue)
    }

    static func load(from defaults: UserDefaults, key: String, fallback: Self) -> Self {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.modifierRawValue & ~modifierMask.rawValue == 0,
              value.keyCode.map({ $0 <= 127 && !value.keyName.isEmpty }) ?? !value.modifiers.isEmpty
        else { return fallback }
        return value
    }

    func save(to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// Carbon hotkeys deliver press/release for just the selected keys. No global
/// keyboard event tap or captured text is needed. Registrations exist only
/// while recording and are suspended while editing a binding.
@MainActor
final class RecordingBindingMonitor {
    private let hotKeys = GlobalHotKeyManager()
    private var held: Set<RecordingBinding> = []
    var onChange: (() -> Void)?

    func start(_ bindings: [RecordingBinding]) -> [RecordingBinding] {
        stop()
        var unavailable: [RecordingBinding] = []
        for (index, binding) in Array(Set(bindings)).enumerated() {
            guard let shortcut = binding.shortcut else { continue }
            if !hotKeys.register(id: UInt32(index + 100), shortcut: shortcut, action: { [weak self] in
                self?.held.insert(binding)
                self?.onChange?()
            }, onRelease: { [weak self] in
                self?.held.remove(binding)
                self?.onChange?()
            }) { unavailable.append(binding) }
        }
        return unavailable
    }

    func isActive(_ binding: RecordingBinding, flags: NSEvent.ModifierFlags) -> Bool {
        binding.matches(flags: flags, keyHeld: held.contains(binding))
    }

    func stop() {
        hotKeys.clear()
        held.removeAll()
    }
}

final class RecordingBindingButton: NSButton {
    var binding = RecordingBinding(.control) {
        didSet { if monitor == nil { title = binding.displayName } }
    }
    var onBeginCapture: (() -> Void)?
    var onChange: ((RecordingBinding) -> Void)?
    private var monitor: Any?
    private var pendingModifiers: NSEvent.ModifierFlags = []

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginCapture)
        title = binding.displayName
        toolTip = "Click, then press a key or key combination. Release modifiers to bind them alone. Escape cancels."
    }

    @objc private func beginCapture() {
        cancelCapture()
        onBeginCapture?()
        pendingModifiers = []
        NotificationCenter.default.post(name: .shortcutCaptureBegan, object: self)
        title = "Press a key…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(RecordingBinding.modifierMask)
            if event.type == .flagsChanged {
                self.pendingModifiers.formUnion(modifiers)
                if modifiers.isEmpty, !self.pendingModifiers.isEmpty {
                    self.accept(RecordingBinding(modifiers: self.pendingModifiers))
                }
                return nil
            }
            if event.keyCode == 53, modifiers.isEmpty {
                self.cancelCapture()
                return nil
            }
            guard !event.isARepeat, let name = ShortcutRecorderButton.keyName(for: event) else { return nil }
            self.accept(RecordingBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: name))
            return nil
        }
    }

    private func accept(_ value: RecordingBinding) {
        cancelCapture()
        binding = value
        onChange?(value)
    }

    func cancelCapture() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        pendingModifiers = []
        title = binding.displayName
        NotificationCenter.default.post(name: .shortcutCaptureEnded, object: self)
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
