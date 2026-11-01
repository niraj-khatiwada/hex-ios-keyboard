import AVFoundation
import SwiftUI

/// One screen: three setup steps that tick themselves off, then "Try it" once everything's ready.
struct ContentView: View {
    @Binding var openedFromKeyboard: Bool
    @EnvironmentObject private var session: DictationSession
    @EnvironmentObject private var mac: MacConnection
    @Environment(\.scenePhase) private var scenePhase

    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var keyboardAdded = false
    @State private var keyboardFullAccess = false
    @State private var showCodeEntry = false
    @State private var code = ""
    @State private var tryText = ""
    @FocusState private var tryFocused: Bool

    private var micReady: Bool { micPermission == .granted }
    private var keyboardReady: Bool { keyboardFullAccess }
    private var stepsDone: Int { [mac.isConnected, micReady, keyboardReady].filter { $0 }.count }
    private var allSet: Bool { stepsDone == 3 }

    var body: some View {
        NavigationStack {
            List {
                // When you're typing in the Try it box, you're already in the right app,
                // so there's nowhere to go back to.
                if openedFromKeyboard && !tryFocused {
                    returnBanner
                }

                header

                // Setup only shows while something's missing; it comes back if anything breaks.
                if !allSet {
                    Section {
                        connectStep
                        micStep
                        keyboardStep
                    } header: {
                        Text("Setup · \(stepsDone) of 3 done")
                    }
                }

                Section {
                    TextField("Tap here, switch to hex-ios-keyboard with 🌐, then hold the mic", text: $tryText, axis: .vertical)
                        .focused($tryFocused)
                        .onChange(of: tryFocused) { _, focused in session.testingInApp = focused }
                        .lineLimit(3...6)
                    dictationStatus
                } header: {
                    Text("Try it")
                }

                Section {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("Show history", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section {
                    Picker("Keep the mic ready for", selection: $session.sessionMinutes) {
                        ForEach(DictationSession.sessionLengthChoices, id: \.self) { minutes in
                            Text(Self.sessionLengthLabel(minutes)).tag(minutes)
                        }
                    }
                    .onChange(of: session.sessionMinutes) { _, _ in session.sessionLengthChanged() }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("iOS only lets this app start the mic while it's on screen. So the first hold opens the app to start a session, and the mic then stays on in the background (orange dot) until the session ends. Audio is only kept while you hold the button.")
                }
            }
            .navigationTitle("hex-ios-keyboard")
            .scrollDismissesKeyboard(.immediately)
            .background(TapToDismissKeyboard())
            .animation(.default, value: stepsDone)
            .animation(.default, value: mac.status)
        }
        .task { await refresh(checkMac: true) }

        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh(checkMac: !mac.isConnected) } }
        }
        .onChange(of: session.isActive) { _, active in
            if !active { openedFromKeyboard = false }
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: allSet ? "checkmark.seal.fill" : "mic.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(allSet ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(allSet ? "You're all set" : "Let's get you set up")
                        .font(.headline)
                    if allSet {
                        Label {
                            Text("\(mac.modelName ?? "Hex")\(mac.engineReady ? "" : " · loading…") on \(mac.hostDescription)")
                        } icon: {
                            Image(systemName: "cpu")
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    Text(allSet
                         ? "In any app, switch to hex-ios-keyboard with 🌐, hold the mic, talk, and let go."
                         : "Finish the steps below. Each one ticks off by itself.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var returnBanner: some View {
        Section {
            if session.isStarting {
                Label { Text("Starting the mic…") } icon: { ProgressView() }
            } else if session.phase == .recording {
                Label("Listening. Tap ◀ in the top-left corner to go back to your app; tap the mic there when you're done.",
                      systemImage: "waveform")
                    .foregroundStyle(.red)
            } else if session.isActive {
                Label("Mic is ready. Tap ◀ in the top-left corner to go back, then use the mic.",
                      systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: Step 1 — Mac

    private var connectStep: some View {
        StepRow(number: 1, title: "Connect to your Mac", done: mac.isConnected, busy: mac.status == .checking) {
            switch mac.status {
            case .checking:
                Text("Looking for your Mac…")
            case .connected(let model):
                HStack {
                    Text("Connected to \(mac.hostDescription) · \(mac.modelName ?? model)\(mac.engineReady ? "" : " (loading model…)")")
                    Spacer()
                    Button("Change") { showCodeEntry = true; mac.forget() }
                        .buttonStyle(.borderless)
                }
            case .notPaired:
                Text("On your Mac, run **bun start** in the mac-server folder. A page opens with a QR code: open your iPhone **Camera**, point it at the code, and tap the link that appears.")
                codeEntry
            case .wrongCode:
                Text("Your Mac didn't accept that code. Scan the QR code again.")
                    .foregroundStyle(.orange)
                codeEntry
            case .unreachable:
                Text("Can't reach your Mac. Check that **bun start** is running and both devices are on the same Wi-Fi. This reconnects by itself the moment the server is back.")
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await mac.check() } }
                    .buttonStyle(.borderedProminent)
                codeEntry
            }
        }
    }

    @ViewBuilder
    private var codeEntry: some View {
        if showCodeEntry {
            HStack {
                TextField("Code from your Mac", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitCode)
                Button("Connect", action: submitCode)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            Button("Can't scan? Type the code instead") { showCodeEntry = true }
                .buttonStyle(.borderless)
                .font(.footnote)
        }
    }

    private func submitCode() {
        let entered = code
        Task {
            await mac.pair(code: entered)
            if mac.isConnected { showCodeEntry = false; code = "" }
        }
    }

    // MARK: Step 2 — Microphone

    private var micStep: some View {
        StepRow(number: 2, title: "Allow the microphone", done: micReady, busy: false) {
            if micReady {
                Text("Allowed")
            } else if micPermission == .denied {
                Text("Microphone access is off. Turn on **Microphone** in Settings.")
                openSettingsButton
            } else {
                Text("The app records your voice while you hold the mic button.")
                Button("Allow microphone") {
                    Task {
                        _ = await AVAudioApplication.requestRecordPermission()
                        micPermission = AVAudioApplication.shared.recordPermission
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Step 3 — Keyboard

    private var keyboardStep: some View {
        StepRow(number: 3, title: "Add the keyboard", done: keyboardReady, busy: false) {
            if keyboardReady {
                Text("hex-ios-keyboard is on with Full Access")
            } else if keyboardAdded {
                Text("Almost there. In Settings → **Keyboards**, turn on **Allow Full Access**. Then switch to hex-ios-keyboard once in the box below.")
                openSettingsButton
            } else {
                Text("In Settings → **Keyboards**, turn on **hex-ios-keyboard** and **Allow Full Access**.")
                openSettingsButton
            }
        }
    }

    private var openSettingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: Dictation status

    @ViewBuilder
    private var dictationStatus: some View {
        switch session.phase {
        case .recording:
            Label("Listening…", systemImage: "waveform").foregroundStyle(.red)
        case .transcribing:
            Label { Text("Transcribing on your Mac…") } icon: { ProgressView() }
        case .error:
            Label(session.lastError ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            if session.isStarting {
                Label { Text("Starting the mic…") } icon: { ProgressView() }
            } else if session.isActive {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Mic ready", systemImage: "mic.fill").foregroundStyle(.green)
                        if let endsAt = session.endsAt {
                            Text("Turns off \(endsAt, style: .relative) from now unless you dictate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Turn off") { session.endSession() }.buttonStyle(.borderless)
                }
            } else {
                Text("The mic turns on when you first hold the mic button, and stays ready \(session.sessionMinutes == 0 ? "until you turn it off" : "for \(Self.sessionLengthLabel(session.sessionMinutes))").")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Refresh

    private func refresh(checkMac: Bool) async {
        micPermission = AVAudioApplication.shared.recordPermission
        keyboardFullAccess = AppGroup.keyboardHasFullAccess
        keyboardAdded = keyboardFullAccess || Self.isKeyboardEnabled()
        if checkMac, mac.status != .checking { await mac.check() }
    }

    /// Whether hex-ios-keyboard is in the user's enabled keyboards.
    private static func isKeyboardEnabled() -> Bool {
        let extensionID = (Bundle.main.bundleIdentifier ?? "") + ".keyboard"
        let selector = NSSelectorFromString("identifier")
        return UITextInputMode.activeInputModes.contains { mode in
            mode.responds(to: selector) && (mode.perform(selector)?.takeUnretainedValue() as? String) == extensionID
        }
    }
}

extension ContentView {
    static func sessionLengthLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Until I turn it off"
        case 60: "1 hour"
        case 1: "1 minute"
        default: "\(minutes) minutes"
        }
    }
}

/// A numbered setup step: shows a spinner while busy and a green check when done.
private struct StepRow<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let busy: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if busy {
                    ProgressView()
                } else if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "\(number).circle").foregroundStyle(Color.accentColor)
                }
            }
            .font(.title2)
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
                    .font(.subheadline)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        }
        .padding(.vertical, 4)
    }
}
