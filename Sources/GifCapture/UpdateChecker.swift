import AppKit

/// Checks GitHub Releases for newer versions. Public builds are ad-hoc signed,
/// so updates use the same visible, checksum-verifying Terminal installer as a
/// first-time install instead of silently replacing executable code.
enum UpdateChecker {
    private struct ReleaseInfo: Sendable {
        let version: String
        let notes: String
        let url: URL
        let hasInstaller: Bool
    }

    private static let apiURL = URL(
        string: "https://api.github.com/repos/RobbieCase/GifCapture/releases/latest"
    )!
    private static let latestReleaseURL = URL(
        string: "https://github.com/RobbieCase/GifCapture/releases/latest"
    )!
    private static let installerURL = URL(
        string: "https://raw.githubusercontent.com/RobbieCase/GifCapture/main/install.sh"
    )!
    private static let requiredAssets = Set(["GifCapture.zip", "GifCapture.zip.sha256"])

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

    private static var isDevSignedCopy: Bool {
        Bundle.main.object(forInfoDictionaryKey: "GifCaptureBuildKind") as? String == "development"
    }

    private static func check(interactive: Bool) async {
        let isDevelopment = isDevSignedCopy
        // Development builds only check on explicit request so local work is not
        // interrupted by the latest public release prompt.
        if isDevelopment, !interactive { return }

        do {
            let release = try await latestRelease()

            if isDevelopment {
                await offerReleaseReplacement(release)
                return
            }

            guard isVersion(release.version, newerThan: currentVersion) else {
                if interactive {
                    await showInfo(
                        "You're up to date",
                        "GifCapture v\(currentVersion) is the latest version."
                    )
                }
                return
            }

            await offerUpdate(release)
        } catch {
            if interactive {
                await showInfo("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    /// Prefer the structured API, but fall back to GitHub's stable latest-release
    /// redirect if an unauthenticated API rate limit or transient API error occurs.
    private static func latestRelease() async throws -> ReleaseInfo {
        do {
            return try await releaseFromAPI()
        } catch {
            return try await releaseFromRedirect()
        }
    }

    private static func releaseFromAPI() async throws -> ReleaseInfo {
        let (data, response) = try await URLSession.shared.data(for: request(apiURL))
        guard let http = response as? HTTPURLResponse else {
            throw updateError("GitHub returned an invalid response.")
        }
        guard http.statusCode == 200 else {
            if [403, 429].contains(http.statusCode),
               http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw updateError("GitHub's update-check limit was reached.")
            }
            throw updateError("GitHub returned HTTP \(http.statusCode).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let releaseString = json["html_url"] as? String,
              let releaseURL = validatedGitHubURL(releaseString)
        else {
            throw updateError("GitHub returned unexpected release information.")
        }

        let assetNames = Set(
            (json["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        )
        return ReleaseInfo(
            version: normalizedVersion(tag),
            notes: String((json["body"] as? String ?? "").prefix(600)),
            url: releaseURL,
            hasInstaller: requiredAssets.isSubset(of: assetNames)
        )
    }

    private static func releaseFromRedirect() async throws -> ReleaseInfo {
        let (_, response) = try await URLSession.shared.data(for: request(latestReleaseURL))
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let finalURL = http.url,
              finalURL.scheme == "https",
              finalURL.host == "github.com",
              finalURL.path.hasPrefix("/RobbieCase/GifCapture/releases/tag/"),
              let tag = finalURL.pathComponents.last,
              !tag.isEmpty
        else {
            throw updateError("GitHub's release page could not be reached.")
        }

        return ReleaseInfo(
            version: normalizedVersion(tag),
            notes: "",
            url: finalURL,
            hasInstaller: await latestInstallerAssetsExist()
        )
    }

    private static func latestInstallerAssetsExist() async -> Bool {
        for name in requiredAssets {
            guard let url = URL(
                string: "https://github.com/RobbieCase/GifCapture/releases/latest/download/\(name)"
            ) else { return false }
            var assetRequest = request(url)
            assetRequest.httpMethod = "HEAD"
            do {
                let (_, response) = try await URLSession.shared.data(for: assetRequest)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(
            "GifCapture/\(currentVersion) (+https://github.com/RobbieCase/GifCapture)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func validatedGitHubURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https",
              url.host == "github.com",
              url.path.hasPrefix("/RobbieCase/GifCapture/releases/")
        else { return nil }
        return url
    }

    private static func normalizedVersion(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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
    private static func offerUpdate(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "GifCapture v\(release.version) is available"
        let availability = release.hasInstaller
            ? "The verified installer will open in Terminal and relaunch GifCapture when finished."
            : "The release is published, but its installer files are not available yet."
        alert.informativeText = "You have v\(currentVersion).\n\n\(availability)\n\n\(release.notes)"
        if release.hasInstaller { alert.addButton(withTitle: "Install Update") }
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if release.hasInstaller, response == .alertFirstButtonReturn {
            launchInstallerOrShowError()
        } else if (release.hasInstaller && response == .alertSecondButtonReturn)
                    || (!release.hasInstaller && response == .alertFirstButtonReturn) {
            NSWorkspace.shared.open(release.url)
        }
    }

    @MainActor
    private static func offerReleaseReplacement(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Replace development build?"
        let availability = release.hasInstaller
            ? "The verified installer will open in Terminal."
            : "Installer files have not been published for this release."
        alert.informativeText = "You're running local development build v\(currentVersion). The latest public release is v\(release.version).\n\n\(availability)\n\n\(release.notes)"
        if release.hasInstaller { alert.addButton(withTitle: "Install Public Release") }
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Keep Development Build")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if release.hasInstaller, response == .alertFirstButtonReturn {
            launchInstallerOrShowError()
        } else if (release.hasInstaller && response == .alertSecondButtonReturn)
                    || (!release.hasInstaller && response == .alertFirstButtonReturn) {
            NSWorkspace.shared.open(release.url)
        }
    }

    @MainActor
    private static func launchInstallerOrShowError() {
        do {
            let commandFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("GifCapture-Update-\(UUID().uuidString)")
                .appendingPathExtension("command")
            let script = """
            #!/bin/bash
            /bin/bash -c "$(/usr/bin/curl --fail --silent --show-error --location '\(installerURL.absoluteString)')"
            STATUS=$?
            /bin/rm -f "$0"
            exit $STATUS
            """
            try script.write(to: commandFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: commandFile.path
            )
            guard NSWorkspace.shared.open(commandFile) else {
                throw updateError("Terminal could not be opened.")
            }
        } catch {
            showInfo("Couldn't start the update", error.localizedDescription)
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
