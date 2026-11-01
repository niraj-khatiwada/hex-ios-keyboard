import AVFoundation
import SwiftUI

/// Runs in the app (in the background while you type elsewhere): keeps the mic running,
/// records on the keyboard's start/stop signals, sends clips to the Mac, and publishes
/// results to the keyboard through the App Group.
@MainActor
final class DictationSession: ObservableObject {
    static let shared = DictationSession()

    /// Choices for how long an unused session keeps the mic ready. 0 means never end.
    static let sessionLengthChoices = [1, 5, 15, 30, 60, 0]

    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var phase: SharedState.Phase = .idle
    @Published private(set) var lastText: String?
    @Published private(set) var lastError: String?
    /// When an idle session will end, for the countdown on screen.
    @Published private(set) var endsAt: Date?

    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("token") var token = ""
    /// End the session (and turn the mic off) after this many minutes without a dictation.
    @AppStorage("sessionMinutes") var sessionMinutes = 5

    /// Restarts the countdown after the session length setting changes.
    func sessionLengthChanged() {
        lastActivity = Date()
        updateEndsAt()
    }

    private let recorder = AudioRecorder()
    private var state = SharedState()
    private var tick: Timer?
    private var tickCount = 0
    private var lastActivity = Date()
    private var uploadTask: Task<Void, Never>?
    private var interrupted = false
    private var recordingStartedAt: Date?
    /// Longest single dictation, so a forgotten tap-to-talk recording can't run forever.
    static let maxClipSeconds: TimeInterval = 5 * 60

    private init() {
        AppGroup.writeState(state)
        DarwinNotifications.shared.observe(.start) { [weak self] in DebugLog.log("got start"); self?.beginRecording() }
        DarwinNotifications.shared.observe(.stop) { [weak self] in DebugLog.log("got stop"); self?.endRecording() }
        DarwinNotifications.shared.observe(.cancel) { [weak self] in DebugLog.log("got cancel"); self?.cancelRecording() }
        DarwinNotifications.shared.observe(.endSession) { [weak self] in self?.endSession(reason: "turned off from keyboard") }
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "entered background"),
                              (UIApplication.willEnterForegroundNotification, "entering foreground"),
                              (UIApplication.willTerminateNotification, "terminating")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in DebugLog.log("\(label) sessionActive=\(self?.isActive ?? false)") }
            }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.level = level }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in self?.handleInterruption(type) }
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
            try recorder.start()
        } catch {
            DebugLog.log("session failed to start: \(error)")
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        DebugLog.log("session started, length=\(sessionMinutes == 0 ? "never ends" : "\(sessionMinutes) min")")
        isActive = true
        interrupted = false
        lastError = nil
        lastActivity = Date()
        updateEndsAt()
        setPhase(.idle)
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    func endSession(reason: String = "turned off") {
        guard isActive else { return }
        DebugLog.log("session ending: \(reason)")
        uploadTask?.cancel()
        tick?.invalidate()
        tick = nil
        recorder.stop()
        isActive = false
        endsAt = nil
        state = SharedState(resultID: state.resultID, resultText: state.resultText, startCount: state.startCount)
        phase = .idle
        AppGroup.writeState(state)
        DarwinNotifications.shared.post(.stateChanged)
    }

    private func onTick() {
        tickCount += 1
        if phase == .idle, let endsAt, Date() > endsAt {
            endSession(reason: "idle for \(sessionMinutes) min")
            return
        }
        if phase == .recording, let started = recordingStartedAt, Date().timeIntervalSince(started) > Self.maxClipSeconds {
            DebugLog.log("clip hit \(Int(Self.maxClipSeconds))s, stopping")
            endRecording()
        }
        if tickCount % 100 == 0 { DebugLog.log("alive phase=\(phase) engineRunning=\(recorder.isRunning)") }
        // While interrupted (a call, Siri) the mic isn't ours, so stop telling the keyboard it's ready.
        guard !interrupted else { return }
        // Heartbeat every 0.5 s; level meter at 10 Hz while recording.
        if phase == .recording || tickCount % 5 == 0 {
            state.heartbeat = Date()
            AppGroup.writeState(state)
        }
    }

    private func updateEndsAt() {
        endsAt = isActive && sessionMinutes > 0 ? lastActivity.addingTimeInterval(TimeInterval(sessionMinutes * 60)) : nil
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isActive else { return }
        switch type {
        case .began:
            DebugLog.log("interruption began")
            interrupted = true
            if phase == .recording { cancelRecording() }
        case .ended:
            DebugLog.log("interruption ended")
            do {
                try recorder.resume()
                interrupted = false
            } catch {
                // iOS doesn't always hand the mic back to a background app.
                DebugLog.log("couldn't resume after interruption: \(error)")
                endSession(reason: "interrupted")
            }
        default:
            break
        }
    }

    // MARK: Recording

    /// Starts recording right away. Used when the keyboard opened the app, so the user can
    /// start talking while iOS switches back to the app they were in.
    func beginRecordingFromKeyboard() {
        DebugLog.log("auto-starting recording")
        beginRecording()
    }

    private func beginRecording() {
        guard isActive, !interrupted else { return }
        recordingStartedAt = Date()
        uploadTask?.cancel()
        lastActivity = Date()
        updateEndsAt()
        state.startCount += 1
        recorder.beginCapture()
        state.level = 0
        state.errorMessage = nil
        setPhase(.recording)
    }

    private func endRecording() {
        guard isActive, phase == .recording else { return }
        lastActivity = Date()
        updateEndsAt()
        let clip = recorder.finishCapture()
        DebugLog.log(String(format: "clip %.1fs peak=%d", clip.seconds, clip.peak))
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
            DebugLog.log("transcribed \(text.count) chars")
            lastText = text
            lastError = nil
            state.resultID = UUID().uuidString
            state.resultText = text
            state.errorMessage = nil
            setPhase(.idle)
        } catch {
            guard !Task.isCancelled else { return }
            DebugLog.log("transcribe failed: \(error)")
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
        DarwinNotifications.shared.post(.stateChanged)
    }
}
