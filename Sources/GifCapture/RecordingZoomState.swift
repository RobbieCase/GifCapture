import Foundation

/// The anchor uses capture-relative coordinates with a top-left origin, so the
/// preview and exported frames use the same center at either display scale.
struct RecordingZoomState: Equatable {
    private(set) var active = false
    private(set) var anchor: CGPoint?
    private var locked = false

    mutating func update(following: Bool, locking: Bool, cursor: CGPoint) {
        if locking && !locked {
            anchor = CGPoint(x: min(1, max(0, cursor.x)), y: min(1, max(0, cursor.y)))
        } else if !locking && following {
            anchor = nil
        }
        // Keep the fixed center during the zoom-out animation.
        active = following || locking
        locked = locking
    }
}
