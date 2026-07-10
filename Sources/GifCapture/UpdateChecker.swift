import AppKit

/// Checks GitHub releases for a newer version and self-updates.
/// The replace-and-relaunch runs in a detached shell so the running app can
/// quit before its own bundle is overwritten.
enum UpdateChecker {
    private static let apiURL = URL(string: "https://api.github.com/repos/RobbieCase/GifCapture/releases/latest")!
    private static let appPath = "/Applications/GifCapture.app"
    private static let bundleID = "com.robbiecase.gifcapture"

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

    /// The build script writes this marker before signing. Certificate authority
    /// text is not reliable for a locally issued identity (`codesign` may report
    /// `Authority=(unavailable)` even when the intended certificate was used).
    private static var isDevSignedCopy: Bool {
        Bundle.main.object(forInfoDictionaryKey: "GifCaptureBuildKind") as? String == "development"
    }

    private static func check(interactive: Bool) async {
        let isDevelopment = isDevSignedCopy
        // Never surface automatic update UI for a local build. A manual check,
        // however, can intentionally return the Mac to the latest GitHub release.
        if isDevelopment, !interactive { return }

        do {
            var request = URLRequest(url: apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw updateError("GitHub returned an unexpected response.")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zipAsset = assets.first(where: { ($0["name"] as? String) == "GifCapture.zip" }),
                  let downloadString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadString),
                  downloadURL.scheme == "https",
                  downloadURL.host == "github.com"
            else {
                if interactive { await showInfo("Couldn't check for updates", "Unexpected response from GitHub.") }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String ?? "").prefix(400)

            if isDevelopment {
                await offerReleaseReplacement(
                    latest: latest,
                    notes: String(notes),
                    downloadURL: downloadURL
                )
                return
            }

            guard isVersion(latest, newerThan: currentVersion) else {
                if interactive {
                    await showInfo("You're up to date", "GifCapture v\(currentVersion) is the latest version.")
                }
                return
            }

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
                try await downloadAndInstall(from: downloadURL, expectedVersion: latest)
            } catch {
                showInfo("Update failed", error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func offerReleaseReplacement(latest: String, notes: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Replace development build?"
        alert.informativeText = "You're running local development build v\(currentVersion). You can replace it with the latest public GitHub release, v\(latest).\n\nScreen Recording permission will be reset and must be granted again.\n\n\(notes)"
        alert.addButton(withTitle: "Install GitHub Release v\(latest)")
        alert.addButton(withTitle: "Keep Development Build")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await downloadAndInstall(from: downloadURL, expectedVersion: latest)
            } catch {
                showInfo("Revert failed", error.localizedDescription)
            }
        }
    }

    private static func downloadAndInstall(from url: URL, expectedVersion: String) async throws {
        guard Bundle.main.bundlePath == appPath else {
            throw updateError("Move GifCapture to /Applications before installing an update.")
        }

        let (tempFile, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw updateError("The update download returned an unexpected response.")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("GifCaptureUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var shouldCleanStaging = true
        defer {
            if shouldCleanStaging { try? FileManager.default.removeItem(at: staging) }
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tempFile.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()

        let newApp = staging.appendingPathComponent("GifCapture.app")
        guard unzip.terminationStatus == 0,
              FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/GifCapture").path)
        else {
            throw updateError("Downloaded update is not a valid app bundle.")
        }

        try validateDownloadedApp(newApp, expectedVersion: expectedVersion)

        // Detached swap: arguments carry the paths rather than interpolating
        // them into shell source. The helper waits for this process to exit,
        // fails fast on any copy/signature error, then relaunches.
        let script = """
        set -euo pipefail
        app_path="$1"
        new_app="$2"
        staging="$3"
        parent_pid="$4"
        replacement="${app_path}.update"
        backup="${app_path}.previous"
        for _ in {1..100}; do
            if ! kill -0 "$parent_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$parent_pid" 2>/dev/null; then exit 1; fi
        rm -rf "$replacement" "$backup"
        ditto --noextattr --noacl --norsrc "$new_app" "$replacement"
        xattr -cr "$replacement" 2>/dev/null || true
        codesign --verify --deep --strict "$replacement"
        mv "$app_path" "$backup"
        if ! mv "$replacement" "$app_path"; then
            mv "$backup" "$app_path"
            exit 1
        fi
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true
        tccutil reset ScreenCapture com.robbiecase.gifcapture >/dev/null 2>&1 || true
        open "$app_path"
        rm -rf "$staging"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = [
            "-c", script, "gifcapture-updater",
            appPath, newApp.path, staging.path,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        try swap.run()
        shouldCleanStaging = false

        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func validateDownloadedApp(_ appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
              bundle.object(forInfoDictionaryKey: "GifCaptureBuildKind") as? String == "release",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "GifCapture",
              let executableURL = bundle.executableURL,
              executableURL.standardizedFileURL.path.hasPrefix(appURL.standardizedFileURL.path + "/"),
              let executableValues = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true
        else {
            throw updateError("The downloaded app's identity or version doesn't match the update.")
        }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", appURL.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw updateError("The downloaded app failed code-signature verification.")
        }
    }

    private static func updateError(_ message: String) -> NSError {
        NSError(
            domain: "GifCapture",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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
