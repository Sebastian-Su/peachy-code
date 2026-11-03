import SwiftUI

/// Preview cards for every skin. Each card draws with its own skin's tokens,
/// not the active one, so all four skies are visible at once.
struct SkinPicker: View {
    var columns = 5
    @State private var customColor: Color = Skin.color(SkinStore.shared.customAccent ?? Self.defaultCustomAccent)

    static let defaultCustomAccent = "#2f8a78"

    var body: some View {
        let store = SkinStore.shared
        let customSkin = Skin.custom(accent: store.customAccent ?? Self.defaultCustomAccent)
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(Skin.builtIn) { skin in
                    SkinCard(skin: skin, isSelected: store.current.id == skin.id) {
                        store.select(skin)
                    }
                }
                SkinCard(skin: customSkin, isSelected: store.current.id == Skin.customId) {
                    store.selectCustom(accent: store.customAccent ?? Self.defaultCustomAccent)
                }
            }
            HStack(spacing: 8) {
                ColorPicker(t("settings.skin_custom_color"), selection: $customColor, supportsOpacity: false)
                    .foregroundColor(Constants.textPrimary)
                Text(t("settings.skin_custom_hint"))
                    .font(.system(size: 11))
                    .foregroundColor(Constants.textMuted)
            }
        }
        .onChange(of: customColor) { _, color in
            if let hex = Self.hex(of: color) { store.selectCustom(accent: hex) }
        }
    }

    static func hex(of color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }
}

struct SkinCard: View {
    let skin: Skin
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                SkyBand(skin: skin)
                    .frame(height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Capsule().fill(Skin.color(skin.accent)).frame(width: 22, height: 6)
                        Capsule().fill(Skin.color(skin.accent2)).frame(width: 10, height: 6)
                    }
                    Capsule().fill(Skin.color(skin.textMuted).opacity(0.5)).frame(width: 46, height: 4)
                    Text(t(skin.nameKey))
                        .font(Constants.heading(size: 12, weight: .bold))
                        .foregroundColor(Skin.color(skin.text))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Skin.color(skin.surface))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Constants.orangePrimary : Constants.border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(skin.nameKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Paper-cut sky band: gradient sky, sun or moon, two layers of clouds.
struct SkyBand: View {
    let skin: Skin

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(
                    colors: [Skin.color(skin.skyTop), Skin.color(skin.skyBottom)],
                    startPoint: .top, endPoint: .bottom
                )
                Circle()
                    .fill(Skin.color(skin.celestialColor))
                    .frame(width: h * 0.42, height: h * 0.42)
                    .overlay(alignment: .topTrailing) {
                        if skin.celestial == .moon {
                            Circle().fill(Skin.color(skin.skyTop))
                                .frame(width: h * 0.32, height: h * 0.32)
                                .offset(x: h * 0.06, y: -h * 0.04)
                        }
                    }
                    .position(x: w * 0.8, y: h * 0.38)
                CloudLayer(seed: 3, height: 0.45)
                    .fill(Skin.color(skin.cloudBack))
                CloudLayer(seed: 7, height: 0.28)
                    .fill(Skin.color(skin.cloudFront))
            }
        }
    }
}

/// A row of overlapping circles along the bottom edge.
struct CloudLayer: Shape {
    let seed: Int
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = rect.maxY - rect.height * height * 0.4
        var x = rect.minX - 10
        var i = seed
        while x < rect.maxX + 10 {
            let r = rect.height * height * (0.55 + CGFloat((i * 37) % 10) / 22)
            path.addEllipse(in: CGRect(x: x, y: base - r * 0.6, width: r * 2.2, height: r * 1.6))
            x += r * 1.6
            i += 1
        }
        path.addRect(CGRect(x: rect.minX, y: base, width: rect.width, height: rect.maxY - base))
        return path
    }
}
