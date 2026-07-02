import Foundation

enum GifConverterError: LocalizedError {
    case toolNotFound(String)
    case processFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) not found. Install it with: brew install \(tool)"
        case .processFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        }
    }
}

enum GifConverter {
    static let outputDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("GifCaptures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// - Parameter pointWidth: the selection width in screen points; combined with the
    ///   output-scale setting to size the GIF (and stop gifski's default ~800px cap
    ///   from blurring larger captures).
    @discardableResult
    static func convert(videoURL: URL, pointWidth: Int) throws -> URL {
        let settings = AppSettings.load()
        let width = max(2, pointWidth * settings.scale.rawValue)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "GifCapture \(formatter.string(from: Date())).gif"
        let outputURL = outputDirectory.appendingPathComponent(name)

        defer { try? FileManager.default.removeItem(at: videoURL) }

        switch settings.encoder {
        case .gifski:
            try runGifski(videoURL: videoURL, outputURL: outputURL, width: width, settings: settings)
        case .ffmpeg:
            try runFFmpeg(videoURL: videoURL, outputURL: outputURL, width: width, settings: settings)
        }
        return outputURL
    }

    private static func runGifski(videoURL: URL, outputURL: URL, width: Int, settings: AppSettings) throws {
        guard let path = locate("gifski") else { throw GifConverterError.toolNotFound("gifski") }
        try run(tool: "gifski", path: path, arguments: [
            "-o", outputURL.path,
            "--fps", String(settings.fps),
            "--quality", String(settings.quality),
            "--width", String(width),
            videoURL.path,
        ])
    }

    private static func runFFmpeg(videoURL: URL, outputURL: URL, width: Int, settings: AppSettings) throws {
        guard let path = locate("ffmpeg") else { throw GifConverterError.toolNotFound("ffmpeg") }
        // ffmpeg has no single quality knob for GIFs; map quality onto palette size.
        let colors = min(256, max(16, settings.quality * 256 / 100))
        let filter = "fps=\(settings.fps),scale=\(width):-1:flags=lanczos,"
            + "split[s0][s1];[s0]palettegen=max_colors=\(colors)[p];"
            + "[s1][p]paletteuse=dither=sierra2_4a"
        try run(tool: "ffmpeg", path: path, arguments: [
            "-y", "-i", videoURL.path,
            "-vf", filter,
            outputURL.path,
        ])
    }

    private static func run(tool: String, path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw GifConverterError.processFailed(tool, String(message.suffix(500)))
        }
    }

    private static func locate(_ tool: String) -> String? {
        // Prefer the copy bundled inside the app (no Homebrew needed).
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/\(tool)").path,
            FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(tool)"
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
