import SwiftUI
import AppKit

/// A single image preserves the unread badge in the system menu bar label.
struct MenuBarIcon: View {
    let image: NSImage
    let hasUnreadNotifications: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: hasUnreadNotifications ? badgedImage : image)
    }

    private var badgedImage: NSImage {
        let base = image
        let tint = colorScheme == .dark ? NSColor.white : NSColor.black
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
    }
}
