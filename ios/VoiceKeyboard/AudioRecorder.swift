import AVFoundation

/// Records 16 kHz mono clips for the keyboard.
///
/// iOS won't let a backgrounded app *activate* recording, so a session is started while the
/// app is in front. Two ways to keep it usable once you go back to the other app:
/// - `.onHold`: play silence to stay alive, and switch the mic on only between
///   `beginCapture()` and `finishCapture()`. The orange mic dot shows only while you hold.
/// - `.alwaysOn`: keep the mic running and drop samples outside a hold.
final class AudioRecorder {
    enum MicMode: String { case onHold, alwaysOn }

    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    private(set) var mode: MicMode = .onHold

    private let inputEngine = AVAudioEngine()
    private let keepAliveEngine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var capturing = false
    private var inputRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        keepAliveEngine.attach(silencePlayer)
    }

    func start(mode: MicMode) throws {
        self.mode = mode
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers keeps the user's music playing.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        // iOS mutes haptics while recording by default, which swallows the keyboard's
        // "listening" tap that fires the moment the mic turns on.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        switch mode {
        case .onHold: try startKeepAlive()
        case .alwaysOn: try startInput()
        }
        log("session started, mode=\(mode.rawValue)")

        // Route changes (AirPods etc.) stop engines; restart whichever should be running.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: inputEngine, queue: .main
        ) { [weak self] _ in
            guard let self, self.inputRunning else { return }
            self.log("input engine config changed, restarting")
            self.stopInput()
            try? self.startInput()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: keepAliveEngine, queue: .main
        ) { [weak self] _ in
            guard let self, self.mode == .onHold else { return }
            self.log("keep-alive engine config changed, restarting")
            try? self.startKeepAlive()
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopInput()
        stopKeepAlive()
        lock.withLock { capturing = false; samples = [] }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log("session stopped")
    }

    /// Starts keeping samples. In `.onHold` mode this switches the mic on, which iOS may refuse
    /// while the app is in the background; the error is thrown so the caller can fall back.
    func beginCapture() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            converter?.reset()
        }
        if !inputRunning {
            let started = Date()
            try startInput()
            log("mic on in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
        lock.withLock { capturing = true }
    }

    /// Stops capturing and returns the clip as 16 kHz mono 16-bit PCM WAV.
    func finishCapture() -> (wav: Data, seconds: Double) {
        let clip = lock.withLock { () -> [Int16] in
            capturing = false
            return samples
        }
        if mode == .onHold { stopInput() }
        return (WAV.encode(samples: clip, sampleRate: Int(Self.sampleRate)), Double(clip.count) / Self.sampleRate)
    }

    func cancelCapture() {
        lock.withLock { capturing = false; samples = [] }
        if mode == .onHold { stopInput() }
    }

    // MARK: Engines

    private func startKeepAlive() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        keepAliveEngine.connect(silencePlayer, to: keepAliveEngine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // zero-filled: one second of silence
        if !keepAliveEngine.isRunning {
            keepAliveEngine.prepare()
            try keepAliveEngine.start()
        }
        silencePlayer.stop()
        silencePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        silencePlayer.play()
    }

    private func stopKeepAlive() {
        silencePlayer.stop()
        keepAliveEngine.stop()
    }

    private func startInput() throws {
        let input = inputEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        inputEngine.prepare()
        do {
            try inputEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            log("mic failed to start: \(error)")
            throw error
        }
        inputRunning = true
    }

    private func stopInput() {
        guard inputRunning else { return }
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        inputRunning = false
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ capturing }), let converter else { return }

        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-6))
            onLevel?(max(0, min(1, (db + 50) / 50)))
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.int16ChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(output.frameLength))
        lock.withLock {
            if capturing { samples.append(contentsOf: chunk) }
        }
    }

    private func log(_ message: String) {
        print("[mic] \(message)")
    }
}

enum WAV {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))                 // PCM
        append(UInt16(1))                 // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))    // byte rate
        append(UInt16(2))                 // block align
        append(UInt16(16))                // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
