import XCTest
@testable import PeachyPet

@MainActor
final class SessionFinishedStoreTests: XCTestCase {
    private func withToastsEnabled(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SessionFinishedStore.enabledKey)
        defaults.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                defaults.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
        }
        body()
    }

    func testWaitingToastUsesConfiguredCompletionDuration() {
        withToastsEnabled {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: SessionFinishedStore.durationKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: SessionFinishedStore.durationKey)
                } else {
                    defaults.removeObject(forKey: SessionFinishedStore.durationKey)
                }
            }
            defaults.set(12.0, forKey: SessionFinishedStore.durationKey)
            let store = SessionFinishedStore()

            store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

            XCTAssertEqual(store.current?.kind, .waitingInput)
            XCTAssertEqual(store.current?.duration, 12.0)
            store.dismiss()
        }
    }

    func testNewToastReplacesCurrentToast() {
        withToastsEnabled {
            let store = SessionFinishedStore()
            store.show(kind: .completed, sessionId: "sid", projectName: "openclaw360")
            let completedId = store.current?.id

            store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

            XCTAssertEqual(store.current?.kind, .waitingInput)
            XCTAssertNotEqual(store.current?.id, completedId)
            store.dismiss()
        }
    }

    func testStaleTimerCannotDismissReplacementToast() {
        withToastsEnabled {
            let store = SessionFinishedStore()
            store.show(kind: .completed, sessionId: "sid", projectName: "openclaw360")
            let completedId = store.current!.id
            store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

            store.dismiss(toastId: completedId)

            XCTAssertEqual(store.current?.kind, .waitingInput)
            store.dismiss()
        }
    }

    func testSessionScopedDismissLeavesOtherSessionToastVisible() {
        withToastsEnabled {
            let store = SessionFinishedStore()
            store.show(kind: .waitingInput, sessionId: "session-a", projectName: "openclaw360")

            store.dismiss(sessionId: "session-b")
            XCTAssertEqual(store.current?.sessionId, "session-a")

            store.dismiss(sessionId: "session-a")
            XCTAssertNil(store.current)
        }
    }

    func testRepeatedSameKindShowKeepsExistingToast() {
        withToastsEnabled {
            let store = SessionFinishedStore()
            store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")
            let firstId = store.current!.id

            store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

            XCTAssertEqual(store.current?.id, firstId)
            store.dismiss()
        }
    }
}
