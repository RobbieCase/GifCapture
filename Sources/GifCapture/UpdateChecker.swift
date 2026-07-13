import AppKit

/// Checks GitHub releases for a newer version. Public builds are ad-hoc signed,
/// so the app deliberately does not execute an in-app replacement: an ad-hoc
/// signature verifies integrity but cannot authenticate the publisher.
enum UpdateChecker {
    private static let apiURL = URL(string: "https://api.github.com/repos/RobbieCase/GifCapture/releases/latest")!

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
                  let releaseString = json["html_url"] as? String,
                  let releaseURL = URL(string: releaseString),
                  releaseURL.scheme == "https",
                  releaseURL.host == "github.com"
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
                    releaseURL: releaseURL
                )
                return
            }

            guard isVersion(latest, newerThan: currentVersion) else {
                if interactive {
                    await showInfo("You're up to date", "GifCapture v\(currentVersion) is the latest version.")
                }
                return
            }

            await offerUpdate(latest: latest, notes: String(notes), releaseURL: releaseURL)
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
    private static func offerUpdate(latest: String, notes: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = "GifCapture v\(latest) is available"
        alert.informativeText = "You have v\(currentVersion).\n\n\(notes)"
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.open(releaseURL)
    }

    @MainActor
    private static func offerReleaseReplacement(latest: String, notes: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Replace development build?"
        alert.informativeText = "You're running local development build v\(currentVersion). You can replace it with the latest public GitHub release, v\(latest).\n\nInstalling the public release may reset Screen Recording permission.\n\n\(notes)"
        alert.addButton(withTitle: "Open GitHub Release v\(latest)")
        alert.addButton(withTitle: "Keep Development Build")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.open(releaseURL)
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
