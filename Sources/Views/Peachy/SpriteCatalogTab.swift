import SwiftUI

/// One online spritesheet catalog (OpenPets or Petdex) inside "Browse more":
/// its own search, a kind filter for Petdex, and a list that scrolls inside the tab.
struct SpriteCatalogTab: View {
    let source: SpritePetSource
    @Environment(AppStore.self) var appStore
    @State private var pets: [SpriteCatalogPet] = []
    @State private var loading = false
    @State private var failed = false
    @State private var query = ""
    @State private var kind: String?

    private static let kinds = [("character", "pets.kind.character"), ("creature", "pets.kind.creature"), ("object", "pets.kind.object")]

    private var results: [SpriteCatalogPet] { SpriteCatalog.filter(pets, query: query, kind: kind) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(Constants.textMuted)
                    TextField(t("pets.search"), text: $query).textFieldStyle(.plain)
                }
                .font(Constants.body(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.border, lineWidth: 1))
                if source == .petdex {
                    Picker("", selection: $kind) {
                        Text(t("pets.kind.all")).tag(String?.none)
                        ForEach(Self.kinds, id: \.0) { Text(t($0.1)).tag(String?.some($0.0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if pets.isEmpty && failed {
                VStack(spacing: 10) {
                    Text(t("pets.source_unreachable")).font(Constants.body(size: 13)).foregroundColor(Constants.textMuted)
                    Button(t("pets.retry")) { Task { await refresh() } }
                        .buttonStyle(BrandGhostButton(color: Constants.accentText))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pets.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(String(format: t("pets.count"), results.count))
                    .font(Constants.body(size: 11)).foregroundColor(Constants.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                ScrollView {
                    // Lazy: only rows on screen load their thumbnails.
                    LazyVStack(spacing: 8) {
                        ForEach(results) { SpriteCatalogRow(pet: $0) }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) {
            pets = appStore.spriteCatalog.cached(source) ?? []
            await refresh()
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            pets = try await appStore.spriteCatalog.load(source)
            failed = false
        } catch {
            failed = true
        }
    }
}

struct SpriteCatalogRow: View {
    let pet: SpriteCatalogPet

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = pet.thumbnail {
                    AsyncImage(url: thumb) { $0.interpolation(.none).resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                } else {
                    Image(systemName: "square.grid.3x3").font(.system(size: 18)).foregroundColor(Constants.textMuted.opacity(0.6))
                }
            }
            .frame(width: 48, height: 48)
            .background(Constants.stage, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(pet.name).font(Constants.heading(size: 14, weight: .bold)).foregroundColor(Constants.textPrimary).lineLimit(1)
                Text([pet.author, pet.source == .petdex ? pet.kind.map { t("pets.kind.\($0)") } : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(Constants.body(size: 12)).foregroundColor(Constants.textMuted).lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
    }
}
