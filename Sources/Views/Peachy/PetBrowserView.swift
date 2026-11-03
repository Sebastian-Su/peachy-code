import SwiftUI

/// Lists pets from the online catalog; picking one downloads, verifies and
/// imports it, after which it can be activated like any other pet.
struct PetBrowserView: View {
    @Environment(AppStore.self) var appStore
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: PetCatalog?
    @State private var loadError: String?
    @State private var installing: String?
    @State private var installed: Set<String> = []
    @State private var installErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t("pets.browse"))
                    .font(Constants.heading(size: 20, weight: .heavy))
                    .foregroundColor(Constants.textPrimary)
                Spacer()
                Button(t("pets.close")) { dismiss() }
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
            }
            .padding(16)
            Divider().overlay(Constants.border)

            Group {
                if let catalog {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(catalog.pets) { entry in row(entry) }
                        }
                        .padding(16)
                    }
                } else if let loadError {
                    VStack(spacing: 10) {
                        Text(loadError)
                            .font(Constants.body(size: 13))
                            .foregroundColor(Constants.textMuted)
                            .multilineTextAlignment(.center)
                        Button(t("pets.retry")) { Task { await load() } }
                            .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Constants.lightBackground)
        .task { await load() }
    }

    private func row(_ entry: PetCatalog.Entry) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.preview) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(Constants.heading(size: 15, weight: .bold))
                    .foregroundColor(Constants.textPrimary)
                Text(entry.size.map { "v\(entry.version) · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "v\(entry.version)")
                    .font(Constants.body(size: 12))
                    .foregroundColor(Constants.textMuted)
                if let error = installErrors[entry.id] {
                    Text(error)
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.destructiveRed)
                }
            }
            Spacer()
            if installing == entry.id {
                ProgressView().controlSize(.small)
            } else if installed.contains(entry.id) {
                Text(t("pets.installed"))
                    .font(Constants.body(size: 12, weight: .semibold))
                    .foregroundColor(Constants.accentText)
            } else {
                Button(t("pets.download")) { Task { await install(entry) } }
                    .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    .disabled(installing != nil)
            }
        }
        .padding(12)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
    }

    private func load() async {
        loadError = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: Constants.petCatalogURL)
            catalog = try JSONDecoder().decode(PetCatalog.self, from: data)
            installed = Set(appStore.mascotStore.mascots.compactMap { $0.templateSlug }
                .filter { $0.hasPrefix("pack:") }.map { String($0.dropFirst(5)) })
        } catch {
            loadError = String(format: t("pets.catalog_unreachable"), error.localizedDescription)
        }
    }

    private func install(_ entry: PetCatalog.Entry) async {
        installing = entry.id
        installErrors[entry.id] = nil
        defer { installing = nil }
        do {
            let (archive, _) = try await URLSession.shared.download(from: entry.download)
            let destination = LocalStorage.appSupportDir.appendingPathComponent("Pets/\(entry.id)", isDirectory: true)
            let config = try PetPackInstaller.install(archive: archive, expectedSHA256: entry.sha256, into: destination)
            appStore.mascotStore.addOrReplacePack(config: config, packId: entry.id)
            installed.insert(entry.id)
        } catch {
            installErrors[entry.id] = error.localizedDescription
        }
    }
}
