import AppKit

enum GifEncoder: String, CaseIterable {
    case gifski
    case ffmpeg

    var displayName: String {
        switch self {
        case .gifski: return "gifski — best quality"
        case .ffmpeg: return "ffmpeg — smaller files"
        }
    }
}

enum OutputScale: Int, CaseIterable {
    case standard = 1
    case retina = 2

    var displayName: String {
        switch self {
        case .standard: return "1× — matches on-screen size"
        case .retina: return "2× — Retina (sharper, much bigger file)"
        }
    }
}

enum ClickIndicatorMode: String, CaseIterable {
    case off
    case everyClick
    case commandClick
    case optionClick
    case controlClick
    case shiftClick

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .everyClick: return "Every click"
        case .commandClick: return "Command-click (⌘)"
        case .optionClick: return "Option-click (⌥)"
        case .controlClick: return "Control-click (⌃)"
        case .shiftClick: return "Shift-click (⇧)"
        }
    }

    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .off: return false
        case .everyClick: return true
        case .commandClick: return flags.contains(.command)
        case .optionClick: return flags.contains(.option)
        case .controlClick: return flags.contains(.control)
        case .shiftClick: return flags.contains(.shift)
        }
    }
}

struct IndicatorColor {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let defaultRed = IndicatorColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
        alpha = Double(rgb.alphaComponent)
    }
}

struct AppSettings {
    var encoder: GifEncoder
    var quality: Int // 1–100
    var fps: Int
    var scale: OutputScale
    var countdownEnabled: Bool
    var showCursor: Bool
    var clickIndicatorMode: ClickIndicatorMode
    var clickIndicatorColor: IndicatorColor
    var startRecordingShortcut: KeyboardShortcut
    var openLibraryShortcut: KeyboardShortcut
    var stopRecordingShortcut: KeyboardShortcut
    var zoomModifier: RecordingModifier
    var drawModifier: RecordingModifier

    static let fpsChoices = [10, 12, 15, 20, 24, 30]

    static func load() -> AppSettings {
        let d = UserDefaults.standard
        let zoomModifier = RecordingModifier(rawValue: d.string(forKey: "zoomModifier") ?? "") ?? .control
        var drawModifier = RecordingModifier(rawValue: d.string(forKey: "drawModifier") ?? "") ?? .shift
        if drawModifier == zoomModifier {
            drawModifier = RecordingModifier.allCases.first { $0 != zoomModifier } ?? .shift
        }
        let indicatorColor: IndicatorColor
        if d.object(forKey: "clickIndicatorRed") != nil {
            indicatorColor = IndicatorColor(
                red: d.double(forKey: "clickIndicatorRed"),
                green: d.double(forKey: "clickIndicatorGreen"),
                blue: d.double(forKey: "clickIndicatorBlue"),
                alpha: d.object(forKey: "clickIndicatorAlpha") != nil
                    ? d.double(forKey: "clickIndicatorAlpha") : 1
            )
        } else {
            indicatorColor = .defaultRed
        }

        return AppSettings(
            encoder: GifEncoder(rawValue: d.string(forKey: "encoder") ?? "") ?? .gifski,
            quality: d.object(forKey: "quality") as? Int ?? 90,
            fps: d.object(forKey: "fps") as? Int ?? 15,
            scale: OutputScale(rawValue: d.integer(forKey: "scale")) ?? .standard,
            countdownEnabled: d.bool(forKey: "countdownEnabled"),
            showCursor: d.object(forKey: "showCursor") as? Bool ?? true,
            clickIndicatorMode: ClickIndicatorMode(rawValue: d.string(forKey: "clickIndicatorMode") ?? "") ?? .off,
            clickIndicatorColor: indicatorColor,
            startRecordingShortcut: KeyboardShortcut.load(
                from: d, prefix: "startRecordingShortcut", fallback: .defaultStartRecording
            ),
            openLibraryShortcut: KeyboardShortcut.load(
                from: d, prefix: "openLibraryShortcut", fallback: .defaultOpenLibrary
            ),
            stopRecordingShortcut: KeyboardShortcut.load(
                from: d, prefix: "stopRecordingShortcut", fallback: .defaultStopRecording
            ),
            zoomModifier: zoomModifier,
            drawModifier: drawModifier
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(encoder.rawValue, forKey: "encoder")
        d.set(quality, forKey: "quality")
        d.set(fps, forKey: "fps")
        d.set(scale.rawValue, forKey: "scale")
        d.set(countdownEnabled, forKey: "countdownEnabled")
        d.set(showCursor, forKey: "showCursor")
        d.set(clickIndicatorMode.rawValue, forKey: "clickIndicatorMode")
        d.set(clickIndicatorColor.red, forKey: "clickIndicatorRed")
        d.set(clickIndicatorColor.green, forKey: "clickIndicatorGreen")
        d.set(clickIndicatorColor.blue, forKey: "clickIndicatorBlue")
        d.set(clickIndicatorColor.alpha, forKey: "clickIndicatorAlpha")
        startRecordingShortcut.save(to: d, prefix: "startRecordingShortcut")
        openLibraryShortcut.save(to: d, prefix: "openLibraryShortcut")
        stopRecordingShortcut.save(to: d, prefix: "stopRecordingShortcut")
        d.set(zoomModifier.rawValue, forKey: "zoomModifier")
        d.set(drawModifier.rawValue, forKey: "drawModifier")
    }
}
