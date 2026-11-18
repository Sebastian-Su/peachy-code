import AppKit
import MarkdownUI
import SwiftUI

@MainActor
final class SessionResultPanel: NSObject, NSWindowDelegate {
    static let shared = SessionResultPanel()

    private var windows: Set<NSWindow> = []

    @discardableResult
    func show(_ report: SessionResultPlugin.Report) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = t("result_hook.report_title")
        panel.minSize = NSSize(width: 420, height: 260)
        panel.contentView = NSHostingView(rootView: SessionResultContent(report: report))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        if let previous = windows.first {
            panel.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
        } else {
            panel.center()
        }
        windows.insert(panel)
        panel.orderFrontRegardless()
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.remove(window) }
    }
}

private struct SessionResultContent: View {
    let report: SessionResultPlugin.Report

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(report.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                } label: {
                    Label(t("result_hook.copy"), systemImage: "doc.on.doc")
                }
            }
            .padding()
            Divider()
            ScrollView {
                Markdown(report.markdown)
                    .markdownImageProvider(ReportImagePlaceholder())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}

// Reports open automatically, so their embedded images must never initiate requests.
private struct ReportImagePlaceholder: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Image(systemName: "photo").foregroundStyle(.secondary)
    }
}
