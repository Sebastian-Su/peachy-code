import Foundation

/// What the inbox "pending" area shows: permission requests (including
/// questions) and sessions waiting for the user's reply, newest first.
enum InboxPending {
    enum Item: Equatable, Identifiable {
        case permission(UUID)
        case waitingInput(String)

        var id: String {
            switch self {
            case .permission(let id): "p-\(id.uuidString)"
            case .waitingInput(let sessionId): "w-\(sessionId)"
            }
        }
    }

    static func build(permissions: [(UUID, Date)], waitingSessions: [(String, Date)]) -> [Item] {
        var seen = Set<String>()
        let all = permissions.map { (Item.permission($0.0), $0.1) } + waitingSessions.map { (Item.waitingInput($0.0), $0.1) }
        return all
            .sorted { $0.1 > $1.1 }
            .compactMap { seen.insert($0.0.id).inserted ? $0.0 : nil }
    }
}
