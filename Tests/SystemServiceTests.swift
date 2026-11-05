import XCTest
@testable import PeachyPet

final class BrewServiceTests: XCTestCase {
    private let json = #"""
    [{"name":"mihomo","status":"started","user":"suzhou","file":"/Users/u/Library/LaunchAgents/sh.brew.mihomo.plist","exit_code":null},
     {"name":"ollama","status":"none","user":null,"file":"/opt/homebrew/opt/ollama/homebrew.mxcl.ollama.plist","exit_code":null},
     {"name":"unbound","status":"error","user":"suzhou","file":"/Users/u/Library/LaunchAgents/homebrew.mxcl.unbound.plist","exit_code":1}]
    """#

    func testParsesBrewListJSON() throws {
        let list = try XCTUnwrap(BrewServices.parse(Data(json.utf8), launchAgentsDir: "/Users/u/Library/LaunchAgents"))
        XCTAssertEqual(list.map(\.name), ["mihomo", "ollama", "unbound"])
        XCTAssertEqual(list.map(\.label), ["sh.brew.mihomo", "homebrew.mxcl.ollama", "homebrew.mxcl.unbound"])
        XCTAssertEqual(list.map(\.registered), [true, false, true], "registered = plist installed in LaunchAgents")
    }

    private func svc(registered: Bool, loaded: Bool) -> SystemService {
        SystemService(label: "sh.brew.mihomo", name: "mihomo", group: .brew, plistPath: registered ? "/Users/u/Library/LaunchAgents/sh.brew.mihomo.plist" : "/opt/x.plist",
                      program: nil, pid: loaded ? 10 : nil, loaded: loaded, autostart: registered)
    }

    /// S27, X4: stop/start/restart only affect this run; `brew services stop` (which
    /// unregisters login start) is never used.
    func testActionsNeverChangeLoginStart() {
        for registered in [true, false] {
            for loaded in [true, false] {
                for action in [SystemServiceAction.start, .stop, .restart] {
                    let cmds = SystemServiceActions.plan(action, for: svc(registered: registered, loaded: loaded), uid: 501)
                    let flat = cmds.map { $0.joined(separator: " ") }
                    XCTAssertFalse(flat.contains { $0.contains("services stop") || $0.contains("services start") || $0.contains("disable") || $0.contains(" enable ") }, "\(action) \(flat)")
                }
            }
        }
    }

    func testStopBootsOutSoKeepAliveCannotRespawn() {
        let cmds = SystemServiceActions.plan(.stop, for: svc(registered: true, loaded: true), uid: 501)
        XCTAssertEqual(cmds, [["/bin/launchctl", "bootout", "gui/501/sh.brew.mihomo"]])
    }

    func testStartLoadsRegisteredPlistOrRunsBrewService() {
        XCTAssertEqual(SystemServiceActions.plan(.start, for: svc(registered: true, loaded: false), uid: 501),
                       [["/bin/launchctl", "bootstrap", "gui/501", "/Users/u/Library/LaunchAgents/sh.brew.mihomo.plist"]])
        XCTAssertEqual(SystemServiceActions.plan(.start, for: svc(registered: false, loaded: false), uid: 501).first?.suffix(3),
                       ["services", "run", "mihomo"])
    }

    func testRestartKickstartsWhenLoaded() {
        XCTAssertEqual(SystemServiceActions.plan(.restart, for: svc(registered: true, loaded: true), uid: 501),
                       [["/bin/launchctl", "kickstart", "-k", "gui/501/sh.brew.mihomo"]])
    }
}
