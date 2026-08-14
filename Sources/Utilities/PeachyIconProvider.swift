import AppKit

enum PeachyIconProvider {
    enum MenuBarState: CaseIterable {
        case idle
        case working
        case attention

        fileprivate var resourceName: String {
            switch self {
            case .idle:
                "menu-bar-idle"
            case .working:
                "menu-bar-working"
            case .attention:
                "menu-bar-attention"
            }
        }
    }

    private static let menuBarPointSize = NSSize(width: 18, height: 18)

    static func brandImage() -> NSImage? {
        guard let url = resourceURL(named: "logo") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func menuBarImage(for state: MenuBarState) -> NSImage? {
        let image = NSImage(size: menuBarPointSize)

        for pixelSize in [18, 36] {
            let resourceName = "\(state.resourceName)-\(pixelSize)"
            guard let url = resourceURL(named: resourceName),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = menuBarPointSize
            image.addRepresentation(representation)
        }

        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }

    private static func resourceURL(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Images")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Images")
    }
}
