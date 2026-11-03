import Foundation

/// Merges notifications, approval records and activity events into one
/// newest-first timeline. Consecutive activity events collapse into a single
/// run so a burst of tool events never pushes notifications off screen.
enum InboxHistory {
    enum Kind: Hashable { case notification, approval, activity }

    struct Source: Equatable, Identifiable {
        let id: UUID
        let date: Date
        let kind: Kind
        let project: String?
    }

    enum Entry: Equatable, Identifiable {
        case single(Source)
        case activityRun([Source])

        var id: UUID {
            switch self {
            case .single(let s): s.id
            case .activityRun(let run): run[0].id
            }
        }
    }

    static func build(_ sources: [Source], project: String? = nil) -> [Entry] {
        let sorted = sources
            .filter { project == nil || $0.project == project }
            .sorted { $0.date > $1.date }
        var entries: [Entry] = []
        var run: [Source] = []
        for source in sorted {
            if source.kind == .activity {
                run.append(source)
                continue
            }
            if !run.isEmpty { entries.append(.activityRun(run)); run = [] }
            entries.append(.single(source))
        }
        if !run.isEmpty { entries.append(.activityRun(run)) }
        return entries
    }
}
