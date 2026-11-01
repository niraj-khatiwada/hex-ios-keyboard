import SwiftUI

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool
    let onGlobe: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onDelete: () -> Void

    @State private var pressing = false

    var body: some View {
        VStack(spacing: 0) {
            // The mic and what's happening, centered in the space above the keys.
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                micButton
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(isError ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 24)
            }
            Spacer(minLength: 4)

            HStack {
                if showsGlobe {
                    key(systemImage: "globe", action: onGlobe)
                }
                key(systemImage: "gearshape", action: model.openSettingsApp)
                    .accessibilityLabel("Open hex-ios-keyboard")
                Button(action: onSpace) {
                    Text("space")
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Space")
                key(systemImage: "return", action: onReturn)
                key(systemImage: "delete.left", action: onDelete)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Mic off floats in the corner so it doesn't push the mic down.
        .overlay(alignment: .topTrailing) {
            if model.sessionAlive, model.phase != .recording, model.phase != .starting {
                Button(action: model.turnOffMic) {
                    Label("Mic off", systemImage: "mic.slash.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemBackground).opacity(0.7), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Turns the microphone off until you dictate again")
                .padding(.top, 10)
                .padding(.trailing, 12)
            }
        }
    }

    private var micButton: some View {
        let recording = model.phase == .recording
        return ZStack {
            // Soft ring that breathes with your voice while listening.
            Circle()
                .fill(recording ? Color.primary.opacity(0.10) : Color.clear)
                .overlay(Circle().strokeBorder(Color.primary.opacity(recording ? 0.18 : 0), lineWidth: 1))
                .frame(width: 136, height: 136)
                .scaleEffect(recording ? 0.85 + CGFloat(model.level) * 0.3 : 0.85)
                .animation(.easeOut(duration: 0.1), value: model.level)
            MicGlass(active: recording, pressed: pressing)
                .frame(width: 104, height: 104)
            if model.phase == .transcribing || model.phase == .opening || model.phase == .starting {
                ProgressView().tint(.primary).scaleEffect(1.4)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    // Listening: dark mic on a bright face. Idle: bright white-to-silver mic.
                    .foregroundStyle(recording
                        ? AnyShapeStyle(Color(.systemBackground))
                        : AnyShapeStyle(LinearGradient(colors: [.primary, .primary.opacity(0.65)],
                                                       startPoint: .top, endPoint: .bottom)))
                    .animation(.easeInOut(duration: 0.2), value: recording)
            }
        }
        .frame(width: 136, height: 136)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in
                    pressing = false
                    model.tap()
                }
        )
        .accessibilityLabel(model.phase == .recording ? "Stop dictating" : "Dictate")
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 52, height: 42)
                .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var isError: Bool {
        if case .message = model.phase { return true }
        return false
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Tap to talk"
        case .opening: "Opening hex-ios-keyboard to start the mic…"
        case .starting: "Starting mic…"
        case .recording: "Listening… tap to send"
        case .transcribing: "Transcribing on your Mac…"
        case .message(let text): text
        }
    }
}

/// The mic button's face, in black and white: clear Liquid Glass when idle and bright white glass
/// while listening (dark and light swap in light mode). Frosted material before iOS 26. Both have
/// a thin grey border.
private struct MicGlass: View {
    let active: Bool
    let pressed: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(active ? Color.primary : Color.clear)
                    .glassEffect(active ? .regular.tint(.primary).interactive() : .regular.interactive(), in: Circle())
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(active ? Color.primary : Color.primary.opacity(0.06)))
                    .shadow(color: .black.opacity(0.3), radius: pressed ? 2 : 8, y: pressed ? 1 : 4)
            }
        }
        .overlay(
            Circle().strokeBorder(
                LinearGradient(colors: [Color(.systemGray2), Color(.systemGray5)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        )
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(duration: 0.25), value: pressed)
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}
