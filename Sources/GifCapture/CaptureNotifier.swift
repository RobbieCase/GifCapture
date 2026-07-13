import AppKit
@preconcurrency import UserNotifications

/// Posts a "GIF saved" notification with the filename and file size.
/// Clicking the notification reveals the file (handled by AppDelegate's
/// UNUserNotificationCenterDelegate conformance).
enum CaptureNotifier {
    static let revealPathKey = "revealPath"

    static func notifySaved(gifURL: URL, mp4URL: URL?) {
        // UNUserNotificationCenter traps when the process isn't a real app
        // bundle (e.g. the offscreen UI test harness).
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "GIF saved"
            var body = gifURL.lastPathComponent
            if let size = fileSize(of: gifURL) {
                body += " — \(size)"
            }
            if let mp4URL {
                body += "\nMP4 copy: \(fileSize(of: mp4URL) ?? "saved")"
            }
            content.body = body
            content.userInfo = [revealPathKey: gifURL.path]

            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    private static func fileSize(of url: URL) -> String? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
