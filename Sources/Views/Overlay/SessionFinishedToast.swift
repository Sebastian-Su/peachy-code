import SwiftUI

struct SessionFinishedToastView: View {
    @Environment(SessionFinishedStore.self) private var store
    @Environment(GlobalHotkeyManager.self) private var hotkeyManager
    @State private var progress: CGFloat = 1.0

    var body: some View {
        if let toast = store.current {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: toast.kind))
                    .font(.system(size: 16))
                    .foregroundStyle(Constants.orangePrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.projectName)
                        .font(Constants.heading(size: 12, weight: .bold))
                        .foregroundStyle(Constants.textPrimary)
                        .lineLimit(1)

                    Text(t(messageKey(for: toast.kind)))
                        .font(Constants.body(size: 10, weight: .medium))
                        .foregroundStyle(Constants.textMuted)
                }

                Spacer(minLength: 4)

                Text("\(hotkeyManager.shortcutLabel) focus · ⌘↵ dismiss")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Constants.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Constants.orangePrimary
                        .frame(width: geo.size.width * progress, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                    .stroke(Constants.border, lineWidth: 1)
            )
            .shadow(color: Constants.cardHoverShadowColor, radius: Constants.cardHoverShadowRadius, x: 0, y: Constants.cardHoverShadowY)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: store.current?.id)
            .onAppear {
                progress = 1.0
                withAnimation(.linear(duration: toast.duration)) {
                    progress = 0
                }
            }
            .onChange(of: store.current?.id) { _, id in
                if id != nil, let toast = store.current {
                    progress = 1.0
                    withAnimation(.linear(duration: toast.duration)) {
                        progress = 0
                    }
                }
            }
        }
    }

    private func iconName(for kind: SessionFinishedStore.Kind) -> String {
        switch kind {
        case .completed: return "checkmark.circle.fill"
        case .waitingInput: return "bubble.left.fill"
        }
    }

    private func messageKey(for kind: SessionFinishedStore.Kind) -> String {
        switch kind {
        case .completed: return "toast.task_completed"
        case .waitingInput: return "toast.waiting_for_input"
        }
    }
}
