import SwiftUI

/// A set of design tokens for the main window. Colors are sRGB hex strings.
struct Skin: Identifiable, Equatable {
    enum Celestial: Equatable { case sun, moon }

    let id: String
    let isDark: Bool
    let accent: String
    let accentHover: String
    let accentShadow: String
    /// Accent used for small text where `accent` is too light to read
    let accentText: String
    /// Text drawn on top of an accent fill
    let onAccent: String
    let accent2: String
    let text: String
    let textMuted: String
    let background: String
    let sidebar: String
    let surface: String
    let surface2: String
    let line: String
    /// Warm hover background base (drawn at 18% opacity)
    let chip: String
    /// Second stop of the feature card gradient (drawn at 6% opacity)
    let gradientEnd: String
    /// Dark "stage" panel behind the mascot
    let stage: String
    let skyTop: String
    let skyBottom: String
    let cloudFront: String
    let cloudBack: String
    let celestialColor: String
    let celestial: Celestial

    /// Localization key of the display name
    var nameKey: String { "skin.\(id)" }

    /// Default skin, sampled from the PeachMilky mascot. The accent is one step
    /// darker than the prototype's champagne #d4a843 because existing views use
    /// it both as text and under white labels; #b8862b keeps their contrast at
    /// the level of the old orange.
    static let cream = Skin(
        id: "cream", isDark: false,
        accent: "#b8862b", accentHover: "#c9963a", accentShadow: "#8a6418",
        accentText: "#7a5a12", onAccent: "#2b2216", accent2: "#2f8a78",
        text: "#2b2216", textMuted: "#5e5340",
        background: "#faf6ec", sidebar: "#f2ead8", surface: "#fffdf7", surface2: "#f3ecdc",
        line: "#e6dcc6", chip: "#e4b46c", gradientEnd: "#f0c060", stage: "#1f1a12",
        skyTop: "#f3e6c4", skyBottom: "#fdf7e8", cloudFront: "#ffffff", cloudBack: "#fbf1da",
        celestialColor: "#f0c060", celestial: .sun
    )

    /// The original PeachyPet orange; existing tokens keep their pre-skin values.
    static let peach = Skin(
        id: "peach", isDark: false,
        accent: "#f95d02", accentHover: "#fb7910", accentShadow: "#c94a01",
        accentText: "#a83a00", onAccent: "#ffffff", accent2: "#c8487f",
        text: "#23113c", textMuted: "#6e627d",
        background: "#faf9f7", sidebar: "#f0eae2", surface: "#ffffff", surface2: "#efeae3",
        line: "#e3dcd2", chip: "#e7ad68", gradientEnd: "#fc9b2b", stage: "#0a0a0a",
        skyTop: "#a9dcf0", skyBottom: "#ffe7c4", cloudFront: "#ffffff", cloudBack: "#fff3e0",
        celestialColor: "#ffb21e", celestial: .sun
    )

    static let dusk = Skin(
        id: "dusk", isDark: false,
        accent: "#f95d02", accentHover: "#fb7910", accentShadow: "#8a2c00",
        accentText: "#a83a00", onAccent: "#ffffff", accent2: "#c8487f",
        text: "#2b1420", textMuted: "#6a4a56",
        background: "#f4e7d9", sidebar: "#ecdac5", surface: "#fffaf3", surface2: "#ebd9c6",
        line: "#dcc5ae", chip: "#fad9bd", gradientEnd: "#c8487f", stage: "#1d0f16",
        skyTop: "#d9608f", skyBottom: "#ffc58e", cloudFront: "#ff9d8c", cloudBack: "#ffc7a3",
        celestialColor: "#fff1c2", celestial: .sun
    )

    static let night = Skin(
        id: "night", isDark: true,
        accent: "#f95d02", accentHover: "#ff7a2e", accentShadow: "#7a2a00",
        accentText: "#ff7a2e", onAccent: "#1a0d06", accent2: "#c8487f",
        text: "#f4ede4", textMuted: "#b8afa5",
        background: "#0a0a0a", sidebar: "#141414", surface: "#1c1c1c", surface2: "#262626",
        line: "#333333", chip: "#35231a", gradientEnd: "#c8487f", stage: "#000000",
        skyTop: "#0a0a0a", skyBottom: "#232323", cloudFront: "#2d2d2d", cloudBack: "#1c1c1c",
        celestialColor: "#f4ede4", celestial: .moon
    )

    static let builtIn: [Skin] = [.cream, .peach, .dusk, .night]
    static let defaultSkin = cream

    /// Maps whatever was saved under the skin key to a skin; anything unreadable
    /// falls back to the default so a bad value can never break launch.
    static func resolve(storedValue: Any?) -> Skin {
        guard let id = storedValue as? String else { return defaultSkin }
        return builtIn.first { $0.id == id } ?? defaultSkin
    }

    // MARK: - Color math

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0
        return (
            Double((value >> 16) & 0xff) / 255,
            Double((value >> 8) & 0xff) / 255,
            Double(value & 0xff) / 255
        )
    }

    static func color(_ hex: String) -> Color {
        let c = rgb(hex)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// WCAG 2 contrast ratio between two sRGB colors.
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let c = rgb(hex)
            func channel(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
