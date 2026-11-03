import SwiftUI

extension Notification.Name {
    static let openConnectionDoctor = Notification.Name("openConnectionDoctor")
}

enum Constants {
    private static let serverPortKey = "serverPort"

    // Web links (opened in browser)
    #if DEBUG
    static let peachyBaseURL = "https://github.com/Sebastian-Su/peachy-code"
    #else
    static let peachyBaseURL = "https://github.com/Sebastian-Su/peachy-code"
    #endif

    // Pet resource center: catalog in a public repo, packs as its Release assets.
    // `petCatalogURL` in user defaults overrides it (local testing).
    static var petCatalogURL: URL {
        UserDefaults.standard.string(forKey: "petCatalogURL").flatMap(URL.init(string:))
            ?? URL(string: "https://raw.githubusercontent.com/Sebastian-Su/peachy-mascots/main/catalog.json")!
    }

    // Source code repository
    static let repoURL = "https://github.com/Sebastian-Su/peachy-code"

    // Local hook server
    static let legacyDefaultServerPort: UInt16 = 49152
    static let defaultServerPort: UInt16 = 45832
    static var serverPort: UInt16 {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: serverPortKey) != nil else {
            return defaultServerPort
        }

        let stored = defaults.integer(forKey: serverPortKey)
        if stored == Int(legacyDefaultServerPort) {
            defaults.set(Int(defaultServerPort), forKey: serverPortKey)
            return defaultServerPort
        }
        return stored > 0 ? UInt16(stored) : defaultServerPort
    }
    static func setServerPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: serverPortKey)
    }

    // Brand colors — read from the active skin (see SkinStore)
    private static var skin: Skin { SkinStore.shared.current }
    static var orangePrimary: Color { Skin.color(skin.accent) }
    static var orangeHover: Color { Skin.color(skin.accentHover) }
    static var orangeShadow: Color { Skin.color(skin.accentShadow) }
    static var textPrimary: Color { Skin.color(skin.text) }
    static var textMuted: Color { Skin.color(skin.textMuted) }
    static var lightBackground: Color { Skin.color(skin.background) }
    static var surfaceWhite: Color { Skin.color(skin.surface) }
    static var border: Color { textPrimary.opacity(0.12) }
    static var borderHover: Color { textPrimary.opacity(0.20) }

    // Interactive state colors (matches website sidebar)
    static var chip: Color { Skin.color(skin.chip).opacity(0.18) }               // warm hover bg
    static var stage: Color { textPrimary.opacity(0.04) }                        // subtle hover
    static var orangePrimaryLight: Color { orangePrimary.opacity(0.10) }         // active item bg
    static var orangePrimarySubtle: Color { orangePrimary.opacity(0.08) }        // selected row bg

    // Redesign tokens (sidebar, paper band, stage panels)
    static var sidebarBackground: Color { Skin.color(skin.sidebar) }
    static var surfaceSecondary: Color { Skin.color(skin.surface2) }
    static var line: Color { Skin.color(skin.line) }
    static var accentText: Color { Skin.color(skin.accentText) }
    static var accentSecondary: Color { Skin.color(skin.accent2) }
    static var stagePanel: Color { Skin.color(skin.stage) }
    static let destructiveRed = Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255)         // #dc2626

    // MARK: - Typography

    /// Bricolage Grotesque — headings, buttons, display text
    static func heading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(weight)
    }

    /// Rubik — body text, labels, metadata
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Rubik", size: size).weight(weight)
    }

    // MARK: - Layout

    static let cornerRadius: CGFloat = 14
    static let cornerRadiusSmall: CGFloat = 10

    // MARK: - Shadows

    /// Default card shadow
    static var cardShadowColor: Color { textPrimary.opacity(0.08) }
    static let cardShadowRadius: CGFloat = 1.5
    static let cardShadowY: CGFloat = 1

    /// Hover card shadow
    static var cardHoverShadowColor: Color { textPrimary.opacity(0.12) }
    static let cardHoverShadowRadius: CGFloat = 6
    static let cardHoverShadowY: CGFloat = 4

    // MARK: - Gradients

    /// Feature card accent tint gradient (matches web)
    static var featureCardGradient: LinearGradient {
        LinearGradient(
            colors: [
                orangePrimary.opacity(0.06),
                Skin.color(skin.gradientEnd).opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
