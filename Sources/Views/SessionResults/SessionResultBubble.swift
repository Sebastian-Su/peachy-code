import SwiftUI

struct SessionResultBubble: View {
    let store: SessionResultStore

    @Environment(\.speechBubbleTailSide) private var tailSide
    @Environment(\.speechBubbleTailPercent) private var tailPercent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let preview = store.preview {
                card(preview)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95, anchor: tailAnchor).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.preview?.report.source.id)
    }

    private var tailAnchor: UnitPoint {
        switch tailSide {
        case .bottom: UnitPoint(x: tailPercent, y: 1)
        case .top: UnitPoint(x: tailPercent, y: 0)
        case .left: UnitPoint(x: 0, y: tailPercent)
        case .right: UnitPoint(x: 1, y: tailPercent)
        case .none: .bottom
        }
    }

    private func card(_ preview: SessionResultStore.Preview) -> some View {
        let report = preview.report
        let shape = SpeechBubbleShape(tailSide: tailSide, tailPercent: tailPercent)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(OverlayStyle.orange)
                Text(t("result_hook.report_title"))
                    .font(Constants.heading(size: 12, weight: .bold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(ceil(preview.remaining(at: context.date)))
                    Text(String(format: t("result_hook.countdown"), remaining))
                        .monospacedDigit()
                        .foregroundStyle(OverlayStyle.textMuted)
                }
                Button {
                    store.dismissPreview()
                } label: {
                    Image(systemName: "xmark").padding(3)
                }
                .buttonStyle(.plain)
                .help(t("result_hook.dismiss"))
                .accessibilityLabel(t("result_hook.dismiss"))
            }
            .font(.system(size: 11))

            Text(report.source.sessionTitle ?? report.source.label)
                .font(Constants.body(size: 11, weight: .semibold))
                .lineLimit(1)

            Text(String(report.markdown.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Constants.body(size: 11, weight: .regular))
                .foregroundStyle(OverlayStyle.textMuted)
                .lineLimit(3)

            HStack {
                Button(t("result_hook.read")) { store.openHistory(reportID: report.source.id) }
                    .font(Constants.body(size: 11, weight: .semibold))
                Spacer()
                Button(t("result_hook.history")) { store.openHistory() }
                    .font(Constants.body(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OverlayStyle.orange)
        }
        .foregroundStyle(OverlayStyle.textPrimary)
        .padding(10)
        .padding(tailSide.paddingEdge, OverlayStyle.tailHeight)
        .background(shape.fill(OverlayStyle.cardBg))
        .overlay(shape.stroke(Constants.border, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: OverlayStyle.cardShadow, radius: 3, x: 0, y: 2)
        .onHover { store.setPreviewHovered($0) }
    }
}
