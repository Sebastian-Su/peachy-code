import Foundation
import Observation

/// Holds the active skin. Views read it through `Constants`, so SwiftUI
/// re-renders them when the skin changes.
@Observable
final class SkinStore {
    static let shared = SkinStore()
    static let defaultsKey = "skinId"

    private(set) var current: Skin
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = Skin.resolve(storedValue: defaults.object(forKey: Self.defaultsKey))
    }

    func select(_ skin: Skin) {
        current = skin
        defaults.set(skin.id, forKey: Self.defaultsKey)
    }
}
