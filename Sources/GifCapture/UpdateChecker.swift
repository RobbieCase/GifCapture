import AppKit

/// Checks GitHub releases for a newer version and self-updates.
/// The replace-and-relaunch runs in a detached shell so the running app can
/// quit before its own bundle is overwritten.
enum UpdateChecker {
    private static let apiURL = URL(string: "https://api.github.com/repos/RobbieCase/GifCapture/releases/latest")!
    private static let appPath = "/Applications/GifCapture.app"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Silent launch-time check; only surfaces UI when an update exists.
    static func checkOnLaunch() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await check(interactive: false)
        }
    }

    /// Menu-invoked check; also reports "up to date" and errors.
    static func checkInteractive() {
        Task { await check(interactive: true) }
    }

    /// True when running the certificate-signed copy from the dev machine's
    /// build script. Installing a release over it would swap in an ad-hoc
    /// signature and break the machine's stable Screen Recording grant.
    private static var isDevSignedCopy: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", Bundle.main.bundlePath]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("Authority=GifCapture Local Dev")
    }

    private static func check(interactive: Bool) async {
        if isDevSignedCopy {
            if interactive {
                await showInfo(
                    "Development build",
                    "This copy was built and signed locally — updates come from the build script, so the auto-updater is disabled on this Mac."
                )
            }
            return
        }
        do {
            var request = URLRequest(url: apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zipAsset = assets.first(where: { ($0["name"] as? String) == "GifCapture.zip" }),
                  let downloadString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadString)
            else {
                if interactive { await showInfo("Couldn't check for updates", "Unexpected response from GitHub.") }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isVersion(latest, newerThan: currentVersion) else {
                if interactive {
                    await showInfo("You're up to date", "GifCapture v\(currentVersion) is the latest version.")
                }
                return
            }

            let notes = (json["body"] as? String ?? "").prefix(400)
            await offerUpdate(latest: latest, notes: String(notes), downloadURL: downloadURL)
        } catch {
            if interactive {
                await showInfo("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    private static func offerUpdate(latest: String, notes: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "GifCapture v\(latest) is available"
        alert.informativeText = "You have v\(currentVersion).\n\n\(notes)"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await downloadAndInstall(from: downloadURL)
            } catch {
                await showInfo("Update failed", error.localizedDescription)
            }
        }
    }

    private static func downloadAndInstall(from url: URL) async throws {
        let (tempFile, _) = try await URLSession.shared.download(from: url)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifCaptureUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tempFile.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()

        let newApp = staging.appendingPathComponent("GifCapture.app")
        guard unzip.terminationStatus == 0,
              FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/GifCapture").path)
        else {
            throw NSError(domain: "GifCapture", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Downloaded update is not a valid app bundle."])
        }

        // Detached swap: waits for this process to exit, replaces the bundle,
        // clears quarantine/stale TCC state, and relaunches.
        let script = """
        sleep 1
        rm -rf "\(appPath)"
        ditto "\(newApp.path)" "\(appPath)"
        xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null
        tccutil reset ScreenCapture com.robbiecase.gifcapture >/dev/null 2>&1
        open "\(appPath)"
        rm -rf "\(staging.path)"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = ["-c", script]
        try swap.run()

        await MainActor.run { NSApp.terminate(nil) }
    }

    @MainActor
    private static func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
