import SwiftUI

/// A set of design tokens for the main window. Colors are sRGB hex strings.
struct Skin: Identifiable, Equatable {
    let id: String
    let accent: String
    let accentHover: String
    let accentShadow: String
    let text: String
    let textMuted: String
    let background: String
    let surface: String
    /// Warm hover background base (drawn at 18% opacity)
    let chip: String
    /// Second stop of the feature card gradient (drawn at 6% opacity)
    let gradientEnd: String

    /// Default skin, sampled from the PeachMilky mascot. The accent is one step
    /// darker than the prototype's champagne #d4a843 because existing views use
    /// it both as text and under white labels; #b8862b keeps their contrast at
    /// the level of the old orange.
    static let cream = Skin(
        id: "cream",
        accent: "#b8862b",
        accentHover: "#c9963a",
        accentShadow: "#8a6418",
        text: "#2b2216",
        textMuted: "#5e5340",
        background: "#faf6ec",
        surface: "#fffdf7",
        chip: "#e4b46c",
        gradientEnd: "#f0c060"
    )

    static let builtIn: [Skin] = [.cream]
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
