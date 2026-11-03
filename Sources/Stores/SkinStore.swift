import Foundation
import Observation

/// Holds the active skin. Views read it through `Constants`, so SwiftUI
/// re-renders them when the skin changes.
@Observable
final class SkinStore {
    static let shared = SkinStore()
    static let defaultsKey = "skinId"

    private(set) var current: Skin

    private init() {
        current = Skin.resolve(storedValue: UserDefaults.standard.object(forKey: Self.defaultsKey))
    }
}
