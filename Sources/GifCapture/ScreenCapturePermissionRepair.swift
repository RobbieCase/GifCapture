import Foundation

enum ScreenCapturePermissionRepair {
    static let bundleID = "com.robbiecase.gifcapture"
    static let registrationTool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Reset only this app's obsolete code-signing requirement. Never reset
    /// all apps, grant access, or edit the TCC database directly.
    static func repair(appURL: URL) async throws {
        try await Task.detached {
            guard Bundle(url: appURL)?.bundleIdentifier == bundleID else {
                throw failure("The installed GifCapture app could not be identified.")
            }
            try runRepair(appPath: appURL.path, execute: run)
        }.value
    }

    static func runRepair(appPath: String, execute: (String, [String]) throws -> Void) throws {
        // Registration must succeed before the bundle-specific reset can work.
        try execute(registrationTool, ["-f", appPath])
        try execute("/usr/bin/tccutil", ["reset", "ScreenCapture", bundleID])
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain the pipe before waiting so an unexpected long error cannot
        // block the helper. Both commands finish without interactive input.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "macOS could not repair Screen Recording access.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GifCapture.PermissionRepair", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
