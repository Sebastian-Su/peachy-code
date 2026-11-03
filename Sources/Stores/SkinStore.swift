import Foundation
import Observation

/// Holds the active skin. Views read it through `Constants`, so SwiftUI
/// re-renders them when the skin changes.
@Observable
final class SkinStore {
    static let shared = SkinStore()
    static let defaultsKey = "skinId"
    static let customAccentKey = "skinCustomAccent"

    private(set) var current: Skin
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = Skin.resolve(
            storedValue: defaults.object(forKey: Self.defaultsKey),
            customAccent: defaults.object(forKey: Self.customAccentKey)
        )
    }

    /// Last picked custom accent, used to seed the color picker.
    var customAccent: String? { defaults.string(forKey: Self.customAccentKey) }

    func select(_ skin: Skin) {
        current = skin
        defaults.set(skin.id, forKey: Self.defaultsKey)
    }

    func selectCustom(accent: String) {
        current = Skin.custom(accent: accent)
        defaults.set(accent, forKey: Self.customAccentKey)
        defaults.set(Skin.customId, forKey: Self.defaultsKey)
    }
}
