import AppKit

/// Resolves and caches app icons by bundle id for session rows.
/// Prefers bundled PNGs (Resources/Images/app-icons/<bundleId>.png) so icons
/// render reliably regardless of sandbox/runtime lookup limits, then falls back
/// to a live NSWorkspace lookup for apps that aren't bundled.
enum AppIconProvider {
    private static var cache: [String: NSImage?] = [:]

    /// App icon for a bundle id, or nil if neither bundled nor resolvable.
    static func icon(forBundleId bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        let resolved = bundledIcon(bundleId) ?? liveIcon(bundleId)
        cache[bundleId] = resolved
        return resolved
    }

    private static func bundledIcon(_ bundleId: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: bundleId,
            withExtension: "png",
            subdirectory: "Images/app-icons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func liveIcon(_ bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
