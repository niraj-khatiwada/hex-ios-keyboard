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
        VStack(spacing: 8) {
            HStack {
                Spacer()
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
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 12)

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(isError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 34)
                .padding(.horizontal)

            micButton

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
    }

    private var micButton: some View {
        let recording = model.phase == .recording
        return ZStack {
            Circle()
                .fill(recording ? Color.red.opacity(0.18) : Color.clear)
                .frame(width: 150, height: 150)
                .scaleEffect(recording ? 0.8 + CGFloat(model.level) * 0.35 : 0.8)
                .animation(.easeOut(duration: 0.1), value: model.level)
            Circle()
                .fill(recording ? Color.red : Color.accentColor)
                .frame(width: 104, height: 104)
                .shadow(radius: pressing ? 1 : 3)
            if model.phase == .transcribing || model.phase == .opening || model.phase == .starting {
                ProgressView().tint(.white).scaleEffect(1.4)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 150, height: 150)
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
