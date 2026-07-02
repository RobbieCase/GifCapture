import Foundation

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

struct AppSettings {
    var encoder: GifEncoder
    var quality: Int // 1–100
    var fps: Int
    var scale: OutputScale

    static let fpsChoices = [10, 12, 15, 20, 24, 30]

    static func load() -> AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            encoder: GifEncoder(rawValue: d.string(forKey: "encoder") ?? "") ?? .gifski,
            quality: d.object(forKey: "quality") as? Int ?? 90,
            fps: d.object(forKey: "fps") as? Int ?? 15,
            scale: OutputScale(rawValue: d.integer(forKey: "scale")) ?? .standard
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(encoder.rawValue, forKey: "encoder")
        d.set(quality, forKey: "quality")
        d.set(fps, forKey: "fps")
        d.set(scale.rawValue, forKey: "scale")
    }
}
