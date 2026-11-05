import XCTest
@testable import PeachyPet

final class ServiceTaskTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    /// S15: no second run while one is going.
    func testCannotExecuteWhileRunning() {
        XCTAssertFalse(TaskRun.canExecute(status: .running(pid: 5)))
        XCTAssertTrue(TaskRun.canExecute(status: .stopped))
        XCTAssertTrue(TaskRun.canExecute(status: nil))
    }

    /// When the job is seen finished, the result is recorded once and the job cleaned up.
    func testFinishRecordsExitCodeDurationAndCleansUp() {
        let started = TaskRun(startedAt: t0, finishedAt: nil, exitCode: nil)
        let stillRunning = started.observe(running: true, lastExit: nil, now: t0.addingTimeInterval(5))
        XCTAssertEqual(stillRunning.run, started)
        XCTAssertFalse(stillRunning.cleanUp)

        let done = started.observe(running: false, lastExit: 1, now: t0.addingTimeInterval(42))
        XCTAssertEqual(done.run.exitCode, 1)
        XCTAssertEqual(done.run.duration, 42)
        XCTAssertTrue(done.cleanUp)

        let again = done.run.observe(running: false, lastExit: nil, now: t0.addingTimeInterval(99))
        XCTAssertEqual(again.run, done.run, "a finished run is not overwritten")
        XCTAssertFalse(again.cleanUp)
    }

    func testRunsPersistAcrossInstances() {
        let suite = "taskruns-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        TaskRunStore(defaults: defaults).set(TaskRun(startedAt: t0, finishedAt: t0.addingTimeInterval(3), exitCode: 0), for: "pull")
        XCTAssertEqual(TaskRunStore(defaults: defaults).run(for: "pull")?.duration, 3)
    }
}
