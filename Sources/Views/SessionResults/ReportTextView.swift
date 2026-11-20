import AppKit
import SwiftUI

/// The report body as one native text view: ⌘A selects all of it, a drag can span every
/// block, and ⌘C copies the selection. Rendering runs off the main thread.
struct ReportTextView: NSViewRepresentable {
    let markdown: String

    static func makeScrollView() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = true
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.linkTextAttributes = [.cursor: NSCursor.pointingHand, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        (scroll.documentView as? NSTextView)?.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.markdown != markdown,
              let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.markdown = markdown
        let palette = ReportTextRenderer.Palette(
            text: NSColor(Constants.textPrimary),
            muted: NSColor(Constants.textMuted),
            link: NSColor(Constants.orangePrimary)
        )
        let markdown = markdown
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = ReportTextRenderer.render(markdown, palette: palette)
            DispatchQueue.main.async {
                // A newer report may have been selected meanwhile.
                guard context.coordinator.markdown == markdown else { return }
                textView.textStorage?.setAttributedString(rendered)
                textView.scroll(.zero)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var markdown: String?

        /// Paths in reports (`/Users/…`) open in Finder or their app; other links open normally.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url.scheme == nil, url.path.hasPrefix("/") {
                let path = url.path.removingPercentEncoding ?? url.path
                return NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            return NSWorkspace.shared.open(url)
        }
    }
}
