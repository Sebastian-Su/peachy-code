import Foundation

/// Controls which downstream systems an event may touch.
enum EventDisposition {
    /// Append to EventStore only. Do not update SessionStore or NotificationStore.
    case recordOnly
    /// Append to EventStore and update SessionStore. May produce high-value notifications
    /// (permissionRequest, toolFailed, etc.) per existing rules in EventProcessor.
    case sessionActivity
    /// Append to EventStore, advance Session to Idle (with 5-min retention), and fire
    /// exactly one completion notification.
    case userVisibleCompletion
}
