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

final class LaunchAgentCatalogTests: XCTestCase {
    private let home = "/Users/u"

    private func plist(_ label: String, _ program: String?, dir: LaunchPlist.Location) -> LaunchPlist {
        LaunchPlist(label: label, program: program, path: "/x/\(label).plist", location: dir, runAtLoad: true)
    }

    /// S24, S25: the user's own agents are operable; app-installed ones are read-only.
    func testClassifiesAgents() {
        let cases: [(LaunchPlist, SystemService.Group?)] = [
            (plist("ai.hermes.gateway", "\(home)/.hermes/hermes-agent/venv/bin/python", dir: .userAgents), .userAgent),
            (plist("ai.hermes.gateway-all", "\(home)/.hermes/bin/gateway-all.sh", dir: .userAgents), .userAgent),
            (plist("com.suzhou.paseo-daemon-start", "/opt/homebrew/bin/paseo", dir: .userAgents), .userAgent),
            (plist("com.google.GoogleUpdater.wake", "\(home)/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", dir: .userAgents), .appAgent),
            (plist("SwitchHosts", "/Applications/SwitchHosts.app/Contents/MacOS/switchhosts", dir: .userAgents), .appAgent),
            (plist("com.citrolabs.keystone.agent", nil, dir: .userAgents), .appAgent),
            (plist("com.tencent.LemonMonitor", "/Applications/Tencent Lemon.app/Contents/MacOS/LemonMonitor", dir: .systemAgents), .appAgent),
            (plist("com.suzhou.utm-clash-bypass", "/usr/local/libexec/utm-clash-bypass", dir: .systemDaemons), .daemon),
            (plist("com.docker.vmnetd", "/Library/PrivilegedHelperTools/com.docker.vmnetd", dir: .systemDaemons), nil),
            (plist("com.qihoo.360safe.daemon", "/Library/Application Support/Qihoo/360Safe/x", dir: .systemDaemons), nil),
        ]
        for (p, expected) in cases {
            XCTAssertEqual(SystemServiceCatalog.group(for: p, home: home), expected, p.label)
        }
    }

    /// A brew service's plist in LaunchAgents is shown once, in the brew group.
    func testBrewAgentIsNotListedTwice() {
        let agents = [plist("sh.brew.mihomo", "/opt/homebrew/opt/mihomo/bin/mihomo", dir: .userAgents),
                      plist("ai.hermes.gateway", "\(home)/.hermes/x", dir: .userAgents)]
        let brew = [BrewServices.Item(name: "mihomo", status: "started", file: "/Users/u/Library/LaunchAgents/sh.brew.mihomo.plist", registered: true)]
        let list = SystemServiceCatalog.build(brew: brew, plists: agents, home: home, state: { _, _ in (false, nil) })
        XCTAssertEqual(list.filter { $0.label == "sh.brew.mihomo" }.map(\.group), [.brew])
        XCTAssertEqual(list.filter { $0.label == "ai.hermes.gateway" }.map(\.group), [.userAgent])
    }

    /// X3: read-only groups never run anything, and no command is ever sudo.
    func testReadOnlyGroupsRunNothing() {
        for group in [SystemService.Group.appAgent, .daemon] {
            let svc = SystemService(label: "x", name: "x", group: group, plistPath: "/x.plist", program: nil, pid: 1, loaded: true, autostart: true)
            XCTAssertFalse(svc.isOperable)
            XCTAssertEqual(SystemServiceActions.perform(.stop, on: svc), "read-only")
        }
        let daemon = SystemService(label: "com.suzhou.utm-clash-bypass", name: "utm", group: .daemon, plistPath: "/Library/LaunchDaemons/com.suzhou.utm-clash-bypass.plist",
                                   program: nil, pid: nil, loaded: true, autostart: true)
        XCTAssertEqual(SystemServiceCatalog.sudoCommand(for: daemon), "sudo launchctl kickstart -k system/com.suzhou.utm-clash-bypass")
    }

    func testParsesPlist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).plist")
        let dict: [String: Any] = ["Label": "ai.hermes.gateway", "ProgramArguments": ["/Users/u/.hermes/venv/bin/python", "-m", "x"], "RunAtLoad": true, "KeepAlive": true]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try XCTUnwrap(LaunchPlist.read(url, location: .userAgents))
        XCTAssertEqual(p.label, "ai.hermes.gateway")
        XCTAssertEqual(p.program, "/Users/u/.hermes/venv/bin/python")
        XCTAssertTrue(p.runAtLoad)
    }
}

final class AutostartTests: XCTestCase {
    private func svc(_ group: SystemService.Group, registered: Bool = true) -> SystemService {
        SystemService(label: "ai.hermes.gateway", name: "hermes", group: group,
                      plistPath: registered ? "/Users/u/Library/LaunchAgents/ai.hermes.gateway.plist" : "/opt/homebrew/opt/x.plist",
                      program: nil, pid: 5, loaded: true, autostart: registered)
    }

    /// S28: turning autostart off only changes the next login, never stops the running process.
    func testDisableOnlyAffectsLogin() {
        let plan = SystemServiceActions.planAutostart(false, for: svc(.userAgent), uid: 501)
        XCTAssertEqual(plan.commands, [["/bin/launchctl", "disable", "gui/501/ai.hermes.gateway"]])
        XCTAssertFalse(plan.startsNow)
        XCTAssertEqual(SystemServiceActions.planAutostart(true, for: svc(.userAgent), uid: 501).commands,
                       [["/bin/launchctl", "enable", "gui/501/ai.hermes.gateway"]])
    }

    /// An unregistered brew service can only be registered by `brew services start`,
    /// which also starts it now; the plan says so for the confirmation dialog.
    func testUnregisteredBrewEnableStartsNow() {
        let plan = SystemServiceActions.planAutostart(true, for: svc(.brew, registered: false), uid: 501)
        XCTAssertEqual(plan.commands.first?.suffix(3), ["services", "start", "hermes"])
        XCTAssertTrue(plan.startsNow)
        XCTAssertEqual(SystemServiceActions.planAutostart(false, for: svc(.brew, registered: true), uid: 501).commands,
                       [["/bin/launchctl", "disable", "gui/501/ai.hermes.gateway"]])
    }

    func testReadOnlyGroupsHaveNoAutostartControl() {
        XCTAssertTrue(SystemServiceActions.planAutostart(false, for: svc(.appAgent), uid: 501).commands.isEmpty)
        XCTAssertTrue(SystemServiceActions.planAutostart(false, for: svc(.daemon), uid: 501).commands.isEmpty)
    }

    func testParsesDisabledList() {
        let out = "disabled services = {\n\t\"sh.brew.mihomo\" => enabled\n\t\"ai.hermes.gateway\" => disabled\n}\n"
        XCTAssertEqual(LaunchdState.parseDisabled(out), ["ai.hermes.gateway"])
    }

    func testAutostartHonorsDisabled() {
        let plists = [LaunchPlist(label: "ai.hermes.gateway", program: "/Users/u/.hermes/x", path: "/x", location: .userAgents, runAtLoad: true)]
        let list = SystemServiceCatalog.build(brew: [], plists: plists, home: "/Users/u", disabled: ["ai.hermes.gateway"],
                                              state: { _, _ in (true, 1) })
        XCTAssertEqual(list.first?.autostart, false)
    }

    /// X4: registered PeachyPet services never write job files into LaunchAgents.
    func testRegisteredServicesNeverUseLaunchAgents() {
        XCTAssertFalse(ServiceLauncher.jobDirectory.path.contains("/LaunchAgents"))
    }
}
