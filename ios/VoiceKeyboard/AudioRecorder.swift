import AVFoundation

/// Keeps the microphone running for the whole session and keeps only the samples between
/// `beginCapture()` and `finishCapture()`.
///
/// iOS won't let a backgrounded app *start* the mic (it records silence), so the session is
/// started while the app is in front and the engine stays running until the session ends.
/// The running engine is also what keeps the app alive in the background (UIBackgroundModes:
/// audio). Wispr Flow, Raycast and Dictus work the same way.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var capturing = false
    private var configObserver: NSObjectProtocol?

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers keeps the user's music playing.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        // iOS mutes haptics while recording by default, which swallows the keyboard's
        // "listening" tap that fires the moment recording starts.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        try startEngine()
        log("mic on")

        // Route changes (AirPods etc.) stop the engine; restart it with the new input format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log("engine config changed, restarting")
            self.engine.inputNode.removeTap(onBus: 0)
            do { try self.startEngine() } catch { self.log("restart failed: \(error)") }
        }
    }

    /// Restarts the engine after an interruption (a call, Siri) if iOS lets us.
    func resume() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        engine.inputNode.removeTap(onBus: 0)
        try startEngine()
        log("mic resumed")
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { capturing = false; samples = [] }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log("mic off")
    }

    func beginCapture() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            converter?.reset()
            capturing = true
        }
    }

    /// Stops capturing and returns the clip as 16 kHz mono 16-bit PCM WAV.
    func finishCapture() -> (wav: Data, seconds: Double, peak: Int16) {
        let clip = lock.withLock { () -> [Int16] in
            capturing = false
            return samples
        }
        let peak = clip.lazy.map { $0 == .min ? .max : abs($0) }.max() ?? 0
        return (WAV.encode(samples: clip, sampleRate: Int(Self.sampleRate)), Double(clip.count) / Self.sampleRate, peak)
    }

    func cancelCapture() {
        lock.withLock { capturing = false; samples = [] }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
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
        DebugLog.log("[mic] \(message)")
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
