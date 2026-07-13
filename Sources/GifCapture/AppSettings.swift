import AppKit

/// Experimental features that are intentionally excluded from normal builds.
/// Launch a local build with GIFCAPTURE_ENABLE_FOLLOW_WINDOW=1 to expose the
/// current follow-window prototype without shipping it to production users.
enum FeatureFlags {
    static let followWindow = ProcessInfo.processInfo.environment["GIFCAPTURE_ENABLE_FOLLOW_WINDOW"] == "1"
}

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

enum CaptureMode: String, CaseIterable {
    case drag
    case window
    case fullScreen

    var displayName: String {
        switch self {
        case .drag: return "Drag Selection"
        case .window: return "Click a Window"
        case .fullScreen: return "Full Screen"
        }
    }
}

enum ClickIndicatorMode: String, CaseIterable {
    case off
    case everyClick
    case modifierClick

    func displayName(modifier: RecordingModifier) -> String {
        switch self {
        case .off: return "Off"
        case .everyClick: return "Every Click"
        case .modifierClick: return "\(modifier.shortName)-click (\(modifier.symbol))"
        }
    }

    func matches(_ flags: NSEvent.ModifierFlags, modifier: RecordingModifier) -> Bool {
        switch self {
        case .off: return false
        case .everyClick: return true
        case .modifierClick: return flags.contains(modifier.eventFlag)
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
    var autoCopyToClipboard: Bool
    var exportMP4: Bool
    var captureMode: CaptureMode
    var followWindow: Bool
    var countdownEnabled: Bool
    var showCursor: Bool
    var clickIndicatorMode: ClickIndicatorMode
    var clickIndicatorModifier: RecordingModifier
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

        let storedClickMode = d.string(forKey: "clickIndicatorMode") ?? ""
        let clickMode: ClickIndicatorMode
        let migratedClickModifier: RecordingModifier?
        switch storedClickMode {
        case "commandClick": clickMode = .modifierClick; migratedClickModifier = .command
        case "optionClick": clickMode = .modifierClick; migratedClickModifier = .option
        case "controlClick": clickMode = .modifierClick; migratedClickModifier = .control
        case "shiftClick": clickMode = .modifierClick; migratedClickModifier = .shift
        default:
            clickMode = ClickIndicatorMode(rawValue: storedClickMode) ?? .off
            migratedClickModifier = nil
        }
        var clickModifier = RecordingModifier(
            rawValue: d.string(forKey: "clickIndicatorModifier") ?? ""
        ) ?? migratedClickModifier ?? .option
        if clickModifier == zoomModifier || clickModifier == drawModifier {
            clickModifier = RecordingModifier.allCases.first {
                $0 != zoomModifier && $0 != drawModifier
            } ?? .option
        }

        let storedQuality = d.object(forKey: "quality") as? Int ?? 90
        let storedFPS = d.object(forKey: "fps") as? Int ?? 15
        return AppSettings(
            encoder: GifEncoder(rawValue: d.string(forKey: "encoder") ?? "") ?? .gifski,
            quality: min(100, max(1, storedQuality)),
            fps: fpsChoices.contains(storedFPS) ? storedFPS : 15,
            scale: OutputScale(rawValue: d.integer(forKey: "scale")) ?? .standard,
            autoCopyToClipboard: d.object(forKey: "autoCopyToClipboard") as? Bool ?? true,
            exportMP4: d.bool(forKey: "exportMP4"),
            captureMode: CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .drag,
            followWindow: FeatureFlags.followWindow && d.bool(forKey: "followWindow"),
            countdownEnabled: d.bool(forKey: "countdownEnabled"),
            showCursor: d.object(forKey: "showCursor") as? Bool ?? true,
            clickIndicatorMode: clickMode,
            clickIndicatorModifier: clickModifier,
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
        d.set(autoCopyToClipboard, forKey: "autoCopyToClipboard")
        d.set(exportMP4, forKey: "exportMP4")
        d.set(captureMode.rawValue, forKey: "captureMode")
        d.set(followWindow, forKey: "followWindow")
        d.set(countdownEnabled, forKey: "countdownEnabled")
        d.set(showCursor, forKey: "showCursor")
        d.set(clickIndicatorMode.rawValue, forKey: "clickIndicatorMode")
        d.set(clickIndicatorModifier.rawValue, forKey: "clickIndicatorModifier")
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
