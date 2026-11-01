import AVFoundation
import SwiftUI

/// Runs in the app (in the background while you type elsewhere): keeps the app alive,
/// records on the keyboard's start/stop signals, sends clips to the Mac, and publishes
/// results to the keyboard through the App Group.
@MainActor
final class DictationSession: ObservableObject {
    static let shared = DictationSession()

    /// End the session (and release the mic) after this long without a dictation.
    static let idleTimeout: TimeInterval = 5 * 60

    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var phase: SharedState.Phase = .idle
    @Published private(set) var lastText: String?
    @Published private(set) var lastError: String?

    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("token") var token = ""
    /// Experimental: switch the mic on only while the mic button is held.
    @AppStorage("micOnHold") var micOnHold = true
    /// The mode the running session actually uses.
    @Published private(set) var micMode: AudioRecorder.MicMode = .onHold

    private let recorder = AudioRecorder()
    private var state = SharedState()
    private var tick: Timer?
    private var tickCount = 0
    private var lastActivity = Date()
    private var uploadTask: Task<Void, Never>?

    private init() {
        AppGroup.writeState(state)
        DarwinNotifications.shared.observe(.start) { [weak self] in self?.beginRecording() }
        DarwinNotifications.shared.observe(.stop) { [weak self] in self?.endRecording() }
        DarwinNotifications.shared.observe(.cancel) { [weak self] in self?.cancelRecording() }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.level = level }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .began { Task { @MainActor in self?.endSession() } }
        }
    }

    // MARK: Session

    func startSession() async {
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off. Turn it on in Settings → hex-ios-keyboard."
            return
        }
        do {
            micMode = micOnHold ? .onHold : .alwaysOn
            try recorder.start(mode: micMode)
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        isActive = true
        lastError = nil
        lastActivity = Date()
        setPhase(.idle)
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    func endSession() {
        guard isActive else { return }
        uploadTask?.cancel()
        tick?.invalidate()
        tick = nil
        recorder.stop()
        isActive = false
        state = SharedState(resultID: state.resultID, resultText: state.resultText, startCount: state.startCount)
        phase = .idle
        AppGroup.writeState(state)
    }

    private func onTick() {
        tickCount += 1
        if phase == .idle, Date().timeIntervalSince(lastActivity) > Self.idleTimeout {
            endSession()
            return
        }
        // Heartbeat every 0.5 s; level meter at 10 Hz while recording.
        if phase == .recording || tickCount % 5 == 0 {
            state.heartbeat = Date()
            AppGroup.writeState(state)
        }
    }

    // MARK: Recording

    private func beginRecording() {
        guard isActive else { return }
        uploadTask?.cancel()
        lastActivity = Date()
        state.startCount += 1
        do {
            try recorder.beginCapture()
        } catch {
            // iOS wouldn't switch the mic on from the background. Keep the mic on from now on;
            // the next hold reopens the app to start that.
            print("[mic] on-hold mode refused by iOS, falling back to always-on: \(error)")
            micOnHold = false
            endSession()
            fail("iOS wouldn't turn the mic on in the background, so the mic will now stay on during a session. Hold the mic again to restart it.")
            return
        }
        state.level = 0
        state.errorMessage = nil
        setPhase(.recording)
    }

    private func endRecording() {
        guard isActive, phase == .recording else { return }
        lastActivity = Date()
        let clip = recorder.finishCapture()
        state.level = 0
        guard clip.seconds >= 0.3 else {
            setPhase(.idle)
            return
        }
        setPhase(.transcribing)
        uploadTask = Task { await self.transcribe(clip.wav) }
    }

    private func cancelRecording() {
        guard isActive else { return }
        uploadTask?.cancel()
        recorder.cancelCapture()
        state.level = 0
        setPhase(.idle)
    }

    private func transcribe(_ wav: Data) async {
        guard let url = URL(string: serverURL), url.host != nil, !token.isEmpty else {
            fail("Open the hex-ios-keyboard app and connect to your Mac")
            return
        }
        do {
            let text = try await MacServerClient(baseURL: url, token: token).transcribe(wav: wav)
            guard !Task.isCancelled else { return }
            lastText = text
            lastError = nil
            state.resultID = UUID().uuidString
            state.resultText = text
            state.errorMessage = nil
            setPhase(.idle)
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? URLError).map { _ in "Can't reach your Mac — is the server running?" }
                ?? error.localizedDescription
            fail(message)
        }
    }

    private func fail(_ message: String) {
        lastError = message
        state.errorMessage = message
        setPhase(.error)
    }

    private func setPhase(_ newPhase: SharedState.Phase) {
        phase = newPhase
        state.phase = newPhase
        if isActive { state.heartbeat = Date() }
        AppGroup.writeState(state)
    }
}
