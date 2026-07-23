import Foundation

/// Central event dispatcher that owns all agent adapters.
/// Routes events from any adapter through a unified pipeline.
@Observable
final class PeachyEventBus {
    private(set) var adapters: [AgentAdapter] = []

    /// Called when any adapter produces a non-blocking event
    var onEvent: ((AgentEvent) -> Void)?
    /// Called when any adapter produces a permission request (with transport for responding)
    var onPermissionRequest: ((AgentEvent, ResponseTransport) -> Void)?
    /// Called when any adapter produces a custom input (state machine variables)
    var onInput: ((String, ConditionValue) -> Void)?

    func register(_ adapter: AgentAdapter) {
        adapter.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
        adapter.onPermissionRequest = { [weak self] event, transport in
            self?.onPermissionRequest?(event, transport)
        }
        adapter.onInput = { [weak self] name, value in
            self?.onInput?(name, value)
        }
        adapters.append(adapter)
    }

    private static func installPreferenceKey(for source: AgentSource) -> String {
        "integrationInstalled.\(source.rawValue)"
    }

    static func isInstallEnabled(
        for source: AgentSource,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = installPreferenceKey(for: source)
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    static func setInstallEnabled(
        _ enabled: Bool,
        for source: AgentSource,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: installPreferenceKey(for: source))
    }

    /// Install hooks/plugins for all registered adapters whose integration is enabled.
    func installAll() {
        for adapter in adapters where Self.isInstallEnabled(for: adapter.source) {
            do {
                try adapter.install()
            } catch {
                print("[PeachyPet] Failed to install \(adapter.source.displayName) hooks: \(error)")
            }
        }
    }

    /// Start all registered adapters
    func startAll() {
        for adapter in adapters {
            do {
                try adapter.start()
            } catch {
                print("[PeachyPet] Failed to start \(adapter.source.displayName) adapter: \(error)")
            }
        }
    }

    /// Stop all registered adapters
    func stopAll() {
        for adapter in adapters {
            adapter.stop()
        }
    }

    /// Get a specific adapter by source type
    func adapter(for source: AgentSource) -> AgentAdapter? {
        adapters.first { $0.source == source }
    }
}
