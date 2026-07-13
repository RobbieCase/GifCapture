import Foundation

enum GifConverterError: LocalizedError {
    case toolNotFound(String)
    case processFailed(String, String)
    case targetSizeNotReached(actual: Int, target: Int)
    case outputAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "\(tool) not found. Install it with: brew install \(tool)"
        case .processFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        case .targetSizeNotReached(let actual, let target):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The smallest export was \(formatter.string(fromByteCount: Int64(actual))), above the \(formatter.string(fromByteCount: Int64(target))) target. Try a shorter trim or smaller dimensions."
        case .outputAlreadyExists(let name):
            return "An export named \(name) already exists. Please try again."
        }
    }
}

enum GifOutputWidth {
    /// New screen recordings are measured in AppKit points and honor the
    /// user's 1x/2x output-size preference.
    case screenPoints(Int)
    /// Imported GIFs already have a concrete pixel width and preserve it.
    case pixels(Int)

    func pixels(using settings: AppSettings) -> Int {
        switch self {
        case .screenPoints(let width):
            return max(2, width * settings.scale.rawValue)
        case .pixels(let width):
            return max(2, width)
        }
    }
}

enum GifConverter {
    /// Timestamped destination in the library root; callers that also produce
    /// sibling files (e.g. an MP4 copy) need the URL before conversion runs.
    static func makeDefaultOutputURL() -> URL {
        uniqueOutputURL(in: outputDirectory, at: Date())
    }

    static func uniqueOutputURL(in directory: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "GifCapture \(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("gif")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(base) \(suffix)")
                .appendingPathExtension("gif")
            suffix += 1
        }
        return candidate
    }

    static let outputDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("GifCaptures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `outputWidth` distinguishes point-sized screen recordings from existing
    /// GIFs whose pixel dimensions should be preserved.
    @discardableResult
    static func convert(
        videoURL: URL,
        outputWidth: GifOutputWidth,
        outputURL explicitOutput: URL? = nil,
        targetBytes: Int? = nil
    ) async throws -> URL {
        let baseSettings = AppSettings.load()
        let baseWidth = outputWidth.pixels(using: baseSettings)

        let outputURL = explicitOutput ?? makeDefaultOutputURL()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryOutput = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial")
            .appendingPathExtension(outputURL.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporaryOutput) }

        guard let targetBytes, targetBytes > 0 else {
            try await encode(videoURL: videoURL, outputURL: temporaryOutput, width: baseWidth, settings: baseSettings)
            try commit(temporaryOutput, to: outputURL)
            return outputURL
        }

        // GIF size is content-dependent, so target-size export is necessarily
        // iterative. Each pass reduces quality first, then dimensions and FPS.
        // Stop at the first pass below the requested ceiling.
        let passes: [(quality: Double, width: Double, fps: Double)] = [
            (1.00, 1.00, 1.00),
            (0.85, 1.00, 1.00),
            (0.72, 0.90, 1.00),
            (0.60, 0.82, 0.85),
            (0.50, 0.72, 0.72),
            (0.40, 0.62, 0.60),
        ]
        var finalBytes = Int.max
        for pass in passes {
            var settings = baseSettings
            settings.quality = max(20, Int((Double(baseSettings.quality) * pass.quality).rounded()))
            settings.fps = max(6, Int((Double(baseSettings.fps) * pass.fps).rounded()))
            let width = max(160, Int((Double(baseWidth) * pass.width).rounded()))
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: temporaryOutput)
            try await encode(videoURL: videoURL, outputURL: temporaryOutput, width: width, settings: settings)
            finalBytes = (try? temporaryOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            if finalBytes <= targetBytes {
                try commit(temporaryOutput, to: outputURL)
                return outputURL
            }
        }
        throw GifConverterError.targetSizeNotReached(actual: finalBytes, target: targetBytes)
    }

    private static func encode(
        videoURL: URL,
        outputURL: URL,
        width: Int,
        settings: AppSettings
    ) async throws {
        switch settings.encoder {
        case .gifski:
            try await runGifski(videoURL: videoURL, outputURL: outputURL, width: width, settings: settings)
        case .ffmpeg:
            try await runFFmpeg(videoURL: videoURL, outputURL: outputURL, width: width, settings: settings)
        }
    }

    private static func runGifski(videoURL: URL, outputURL: URL, width: Int, settings: AppSettings) async throws {
        guard let path = locate("gifski") else { throw GifConverterError.toolNotFound("gifski") }
        try await run(tool: "gifski", path: path, arguments: [
            "-o", outputURL.path,
            "--fps", String(settings.fps),
            "--quality", String(settings.quality),
            "--width", String(width),
            videoURL.path,
        ])
    }

    private static func runFFmpeg(videoURL: URL, outputURL: URL, width: Int, settings: AppSettings) async throws {
        guard let path = locate("ffmpeg") else { throw GifConverterError.toolNotFound("ffmpeg") }
        // ffmpeg has no single quality knob for GIFs; map quality onto palette size.
        let colors = min(256, max(16, settings.quality * 256 / 100))
        let filter = "fps=\(settings.fps),scale=\(width):-1:flags=lanczos,"
            + "split[s0][s1];[s0]palettegen=max_colors=\(colors)[p];"
            + "[s1][p]paletteuse=dither=sierra2_4a"
        try await run(tool: "ffmpeg", path: path, arguments: [
            "-y", "-i", videoURL.path,
            "-vf", filter,
            outputURL.path,
        ])
    }

    private static func run(tool: String, path: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        let errorData = LockedData()
        let processState = ProcessState(process)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            errorData.append(handle.availableData)
        }
        defer { stderrPipe.fileHandleForReading.readabilityHandler = nil }

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else if processState.reason == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if processState.reason == .timedOut {
                        continuation.resume(throwing: GifConverterError.processFailed(
                            tool, "Timed out after 10 minutes."
                        ))
                    } else {
                        continuation.resume(throwing: GifConverterError.processFailed(
                            tool,
                            String(data: errorData.value.suffix(2_000), encoding: .utf8) ?? "unknown error"
                        ))
                    }
                }
                do {
                    if processState.reason == .cancelled { throw CancellationError() }
                    try process.run()
                    processState.terminateIfRequested()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
                        processState.timeOut()
                    }
                }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            processState.cancel()
        }
    }

    static func commit(_ temporaryURL: URL, to outputURL: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: outputURL.path) else {
            throw GifConverterError.outputAlreadyExists(outputURL.lastPathComponent)
        }
        let bytes = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else {
            throw GifConverterError.processFailed("encoder", "The encoder produced an empty file.")
        }
        do {
            try fm.moveItem(at: temporaryURL, to: outputURL)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw GifConverterError.outputAlreadyExists(outputURL.lastPathComponent)
        }
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock {
                storage.append(data)
                if storage.count > 8_192 { storage.removeFirst(storage.count - 8_192) }
            }
        }

        var value: Data { lock.withLock { storage } }
    }

    private final class ProcessState: @unchecked Sendable {
        enum StopReason: Equatable { case none, cancelled, timedOut }
        private let lock = NSLock()
        private let process: Process
        private var stopReason: StopReason = .none

        init(_ process: Process) { self.process = process }

        var reason: StopReason { lock.withLock { stopReason } }

        func cancel() {
            let shouldTerminate = lock.withLock { () -> Bool in
                guard stopReason == .none else { return false }
                stopReason = .cancelled
                return process.isRunning
            }
            if shouldTerminate { process.terminate() }
        }

        func timeOut() {
            let shouldTerminate = lock.withLock { () -> Bool in
                guard stopReason == .none, process.isRunning else { return false }
                stopReason = .timedOut
                return true
            }
            if shouldTerminate { process.terminate() }
        }

        func terminateIfRequested() {
            if reason != .none, process.isRunning { process.terminate() }
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
