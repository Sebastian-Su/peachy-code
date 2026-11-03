import XCTest
@testable import PeachyPet

final class InboxHistoryTests: XCTestCase {
    private func src(_ kind: InboxHistory.Kind, _ t: TimeInterval, _ project: String? = "p") -> InboxHistory.Source {
        .init(id: UUID(), date: Date(timeIntervalSince1970: t), kind: kind, project: project)
    }

    func testNewestFirstAndActivityRunsCollapse() {
        let n = src(.notification, 5), e4 = src(.activity, 4), e3 = src(.activity, 3), a = src(.approval, 2), e1 = src(.activity, 1)
        let entries = InboxHistory.build([e1, a, e3, n, e4])
        XCTAssertEqual(entries, [.single(n), .activityRun([e4, e3]), .single(a), .activityRun([e1])])
    }

    func testNothingIsLostWhenMerging() {
        var sources: [InboxHistory.Source] = []
        for i in 0..<500 { sources.append(src(.notification, Double(i * 3))) }
        for i in 0..<500 { sources.append(src(.approval, Double(i * 3 + 1))) }
        for i in 0..<1000 { sources.append(src(.activity, Double(i) * 1.5 + 0.2)) }
        let entries = InboxHistory.build(sources)
        var counts: [InboxHistory.Kind: Int] = [:]
        for entry in entries {
            switch entry {
            case .single(let s): counts[s.kind, default: 0] += 1
            case .activityRun(let run): counts[.activity, default: 0] += run.count
            }
        }
        XCTAssertEqual(counts, [.notification: 500, .approval: 500, .activity: 1000])
    }

    func testActivityNeverTakesMoreThanOneRowBetweenNotifications() {
        let sources = [src(.notification, 100)] + (0..<50).map { src(.activity, Double(99 - $0)) } + [src(.notification, 10)]
        XCTAssertEqual(InboxHistory.build(sources).count, 3)
    }

    func testProjectFilter() {
        let a = src(.notification, 3, "alpha"), b = src(.notification, 2, "beta"), c = src(.activity, 1, "alpha")
        XCTAssertEqual(InboxHistory.build([a, b, c], project: "alpha"), [.single(a), .activityRun([c])])
    }
}
