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

    private var micReady: Bool { micPermission == .granted }
    private var keyboardReady: Bool { keyboardFullAccess }
    private var stepsDone: Int { [mac.isConnected, micReady, keyboardReady].filter { $0 }.count }
    private var allSet: Bool { stepsDone == 3 }

    var body: some View {
        NavigationStack {
            List {
                if openedFromKeyboard {
                    returnBanner
                }

                header

                Section {
                    connectStep
                    micStep
                    keyboardStep
                } header: {
                    Text(allSet ? "Setup" : "Setup · \(stepsDone) of 3 done")
                }

                Section {
                    TextField("Tap here, switch to hex-ios-keyboard with 🌐, then hold the mic", text: $tryText, axis: .vertical)
                        .lineLimit(3...6)
                    dictationStatus
                } header: {
                    Text("Try it")
                }

                Section {
                    Toggle("Mic only while holding", isOn: $session.micOnHold)
                        .onChange(of: session.micOnHold) { _, _ in
                            // Takes effect when the next session starts.
                            session.endSession()
                        }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text(session.micOnHold
                         ? "Experimental. The mic is off between holds, and the orange mic dot shows only while you hold. If iOS won't allow it, this turns off by itself."
                         : "The mic stays on (orange dot) during a session so it can record the moment you hold. Audio is only kept while you hold.")
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
            } else if session.isActive {
                Label("Mic is ready. Tap ◀ in the top-left corner to go back, then hold the mic again.",
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
                    Text("Connected to \(mac.hostDescription) · \(model)")
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
                Text("Can't find your Mac. Check that **bun start** is running and both devices are on the same Wi-Fi.")
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
                    if session.micMode == .onHold {
                        Label("Ready · mic turns on only while you hold", systemImage: "mic").foregroundStyle(.green)
                    } else {
                        Label("Ready · mic stays on", systemImage: "mic.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Turn off") { session.endSession() }.buttonStyle(.borderless)
                }
            } else {
                Text("Dictation starts by itself when you first hold the mic button, and turns off after 5 idle minutes.")
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
