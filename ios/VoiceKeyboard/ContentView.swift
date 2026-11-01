import AVFoundation
import SwiftUI

/// One screen: three setup steps that tick themselves off, then "Try it" once everything's ready.
struct ContentView: View {
    @Binding var openedFromKeyboard: Bool
    @EnvironmentObject private var session: DictationSession
    @EnvironmentObject private var mac: MacConnection
    @EnvironmentObject private var returner: ReturnController
    @Environment(\.scenePhase) private var scenePhase

    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var keyboardAdded = false
    @State private var keyboardFullAccess = false
    @State private var showCodeEntry = false
    @State private var code = ""
    @State private var tryText = ""
    @State private var showChangeMac = false
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
                    TextField("Tap here, switch to hex-ios-keyboard with 🌐, then tap the mic", text: $tryText, axis: .vertical)
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
                    Text("iOS only lets this app start the mic while it's on screen. So the first tap opens the app to start a session, and the mic then stays on in the background (orange dot) until the session ends. Audio is only kept while you're dictating.")
                }
            }
            .navigationTitle("hex-ios-keyboard")
            .sheet(isPresented: $showChangeMac) {
                ChangeMacSheet().environmentObject(mac)
            }
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
            if !active {
                openedFromKeyboard = false
                returner.reset()
            }
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
                        HStack(alignment: .firstTextBaseline) {
                            Label {
                                Text("\(mac.modelName ?? "Hex")\(mac.engineReady ? "" : " · loading…") · \(mac.isViaTailscale ? "via Tailscale" : "home Wi-Fi")")
                            } icon: {
                                Image(systemName: "cpu")
                            }
                            .font(.subheadline.weight(.medium))
                            Spacer(minLength: 4)
                            Button("Change") { showChangeMac = true }
                                .font(.subheadline)
                                .buttonStyle(.borderless)
                        }
                    }
                    Text(allSet
                         ? "In any app, switch to hex-ios-keyboard with 🌐, tap the mic, talk, and tap again to send."
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
            } else if returner.status == .returning {
                Label { Text("Going back to your app…") } icon: { ProgressView() }
            } else if session.isActive {
                VStack(alignment: .leading, spacing: 10) {
                    if session.phase == .recording {
                        Label("Listening. Go back to your app and tap the mic there when you're done.", systemImage: "waveform")
                            .foregroundStyle(.red)
                    } else {
                        Label("Mic is ready. Go back to your app to dictate.", systemImage: "mic.fill")
                            .foregroundStyle(.green)
                    }
                    if case .manual(let host?) = returner.status {
                        Button {
                            returner.reopen(host)
                        } label: {
                            Label("Back to \(host.name)", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Swipe right along the bottom edge of the screen, or tap ◀ in the top-left corner.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    Text("Connected \(mac.isViaTailscale ? "via Tailscale" : "on home Wi-Fi") (\(mac.hostDescription)) · \(mac.modelName ?? model)\(mac.engineReady ? "" : " (loading model…)")")
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
                Text(mac.hasTailscaleAddress
     ? "Can't reach your Mac. Check that **bun start** is running, the Mac is awake, and Tailscale is on on both devices. This reconnects by itself the moment it's back."
     : "Can't reach your Mac. Check that **bun start** is running and both devices are on the same Wi-Fi. To dictate away from home, set up Tailscale on both. This reconnects by itself the moment it's back.")
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
                Text("The app records your voice between your taps on the mic button.")
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
                Text("The mic turns on when you first tap the mic button, and stays ready \(session.sessionMinutes == 0 ? "until you turn it off" : "for \(Self.sessionLengthLabel(session.sessionMinutes))").")
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

/// Re-pair with the Mac from the all-set screen: scan the dashboard's QR code, or type its code.
/// The current connection keeps working until the new code connects.
private struct ChangeMacSheet: View {
    @EnvironmentObject private var mac: MacConnection
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("On your Mac, open the dashboard and click **Reconnect iPhone**.", systemImage: "desktopcomputer")
                    Label("Scan its QR code with the iPhone **Camera** and tap the link. That's all.", systemImage: "qrcode.viewfinder")
                } header: {
                    Text("Scan the QR code")
                }

                Section {
                    TextField("Code from your Mac", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(connect)
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(connecting || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("Or type the code")
                } footer: {
                    Text("The code is shown under the QR code. Your Mac is found on the network automatically.")
                }

                Section {
                    LabeledContent("Connected to", value: mac.isViaTailscale ? "\(mac.hostDescription) (Tailscale)" : mac.hostDescription)
                    if let model = mac.modelName { LabeledContent("Model", value: model) }
                } header: {
                    Text("Right now")
                }
            }
            .navigationTitle("Change Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            // Scanning the QR code re-pairs while this is open; close once that connects.
            .onChange(of: mac.status) { _, status in
                if case .connected = status, connecting == false, code.isEmpty { dismiss() }
            }
        }
    }

    private func connect() {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        let previous = mac.token
        connecting = true
        error = nil
        Task {
            await mac.pair(code: entered)
            connecting = false
            if mac.isConnected {
                dismiss()
            } else {
                error = mac.status == .wrongCode
                    ? "Your Mac didn't accept that code. Check it on the dashboard."
                    : "Couldn't reach your Mac with that code."
                // Keep the old pairing working if the new code didn't.
                await mac.pair(code: previous)
            }
        }
    }
}
