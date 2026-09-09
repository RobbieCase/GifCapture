import ScreenCaptureKit

/// ScreenCaptureKit is the authority for the API we actually record with.
/// A negative Core Graphics preflight must not prevent trying that API.
@MainActor
final class ScreenCaptureAccess {
    static let shared = ScreenCaptureAccess()
    private(set) var isChecking = false
    private(set) var hasVerifiedAccess = false
    private let loadDisplays: () async throws -> [SCDisplay]

    init(loadDisplays: @escaping () async throws -> [SCDisplay] = {
        try await SCShareableContent.current.displays
    }) {
        self.loadDisplays = loadDisplays
    }

    /// Coalesce repeated Record clicks while macOS is answering the request.
    /// Never persist a grant or denial across launches or recording attempts.
    func displaysForRecording() async throws -> [SCDisplay]? {
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }
        do {
            let displays = try await loadDisplays()
            hasVerifiedAccess = true
            return displays
        } catch {
            hasVerifiedAccess = false
            throw error
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.userDeclined.rawValue
    }
}
