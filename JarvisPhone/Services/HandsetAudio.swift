import AVFoundation
import Foundation

private func audioFailure(_ message: String) -> NSError {
    NSError(domain: "JarvisAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// AVAudioEngine delivers tap buffers serially on its audio thread.
private final class MicrophoneFrames: @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<Data, Error>
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let output: Stream.Continuation
    private var ended = false
    private var samples = 0
    private var voiced = 0
    private var silence = 0

    init(input: AVAudioFormat, output: Stream.Continuation) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else {
            throw audioFailure("Formato do microfone indisponível.")
        }
        self.format = format
        self.converter = converter
        self.output = output
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard !ended, buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            ended = true
            output.finish(throwing: audioFailure("Falha ao preparar o áudio do microfone."))
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            ended = true
            output.finish(throwing: error ?? audioFailure("Falha na conversão do microfone."))
            return
        }
        let count = Int(pcm.frameLength)
        guard count > 0, let channel = pcm.int16ChannelData?[0] else { return }
        var energy = 0.0
        for i in 0..<count {
            let level = Double(channel[i]) / 32768
            energy += level * level
        }
        samples += count
        if energy / Double(count) >= 0.007 * 0.007 {
            voiced += count
            silence = 0
        } else {
            silence += count
        }
        // The bridge accepts at most 6,400 bytes per microphone frame.
        for offset in stride(from: 0, to: count, by: 1600) {
            let frame = Data(bytes: channel.advanced(by: offset), count: min(1600, count - offset) * 2)
            if case .dropped = output.yield(frame) {
                ended = true
                output.finish(throwing: audioFailure("A rede não acompanhou o microfone."))
                return
            }
        }
        if (voiced >= 1920 && silence >= 16000) || (voiced == 0 && samples >= 96000) || samples >= 208000 {
            ended = true
            output.finish()
        }
    }
}

@MainActor final class HandsetAudio {
    private let session = AVAudioSession.sharedInstance()
    private var captureEngine: AVAudioEngine?
    private var captureOutput: AsyncThrowingStream<Data, Error>.Continuation?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackGeneration = UUID()
    private var queuedBytes = 0
    private var levels: [Double] = []
    private var meterEnergy: Double = 0
    private var meterSamples = 0
    func playbackLevel() -> Double {
        guard let player, let t = player.lastRenderTime, let p = player.playerTime(forNodeTime: t), p.sampleRate > 0 else { return 0 }
        let i = Int(Double(p.sampleTime) / p.sampleRate * 25)
        return levels.indices.contains(i) ? levels[i] : 0
    }
    private var playbackFinished = false
    private var sessionActive = false
    private var interruptionObserver: NSObjectProtocol?
    var onSpeakingChanged: ((Bool) -> Void)?
    var onInterrupted: (() -> Void)?
    var sharesWakeSession: (() -> Bool)?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            MainActor.assumeIsolated {
                guard let self, self.sessionActive else { return }
                self.stop()
                self.onInterrupted?()
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func startCapture() async throws -> AsyncThrowingStream<Data, Error> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw audioFailure("Permita o microfone nos Ajustes do iPhone.")
        }
        try Task.checkCancellation()
        stop()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            sessionActive = true
            let engine = AVAudioEngine()
            let input = engine.inputNode
            // Enable before reading the format: Voice I/O can change the sample rate.
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
                throw audioFailure("O microfone está indisponível.")
            }
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(96))
            let frames = try MicrophoneFrames(input: hardware, output: continuation)
            input.installTap(onBus: 0, bufferSize: 1024, format: hardware, block: frames.receive)
            captureEngine = engine
            captureOutput = continuation
            engine.prepare()
            try engine.start()
            return stream
        } catch {
            stop()
            throw error
        }
    }

    @discardableResult func endCapture() -> Bool {
        guard let engine = captureEngine else { return false }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        captureEngine = nil
        captureOutput?.finish()
        captureOutput = nil
        releaseSession()
        return true
    }

    func enqueue(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count.isMultiple(of: 2), bytes.count <= 24 * 1024 * 1024 - queuedBytes else {
            throw audioFailure("O áudio da resposta excedeu o limite ou veio incompleto.")
        }
        if playbackEngine == nil {
            do {
                if sharesWakeSession?() != true {
                    try session.setCategory(.playback, mode: .spokenAudio)
                    try session.setActive(true)
                }
                sessionActive = true
                let engine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else {
                    throw audioFailure("Formato da resposta indisponível.")
                }
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                player = node
                playbackEngine = engine
                playbackFormat = format
                playbackFinished = false
                engine.prepare()
                try engine.start()
            } catch {
                stopPlayback()
                throw error
            }
        }
        let count = bytes.count / 2
        guard let format = playbackFormat, let node = player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw audioFailure("Falha ao preparar a resposta.") }
        buffer.frameLength = AVAudioFrameCount(count)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let value = raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self)
                channel[i] = Float(Int16(littleEndian: value)) / 32768
                meterEnergy += Double(channel[i] * channel[i]); meterSamples += 1
                if meterSamples == 960 {
                    levels.append(min(1, sqrt(meterEnergy / 960) * 4))
                    meterSamples = 0; meterEnergy = 0
                }
            }
        }
        let generation = playbackGeneration
        let size = bytes.count
        let wasSilent = queuedBytes == 0
        queuedBytes += size
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                self.queuedBytes -= size
                if self.queuedBytes == 0 {
                    self.onSpeakingChanged?(false)
                    if self.playbackFinished { self.stopPlayback() }
                }
            }
        }
        if !node.isPlaying { node.play() }
        if wasSilent { onSpeakingChanged?(true) }
    }

    func finishPlayback() {
        playbackFinished = true
        if queuedBytes == 0 { stopPlayback() }
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        levels.removeAll(keepingCapacity: false); meterEnergy = 0; meterSamples = 0
        let wasSpeaking = queuedBytes > 0
        queuedBytes = 0
        playbackFinished = false
        player?.stop()
        playbackEngine?.stop()
        player = nil
        playbackEngine = nil
        playbackFormat = nil
        releaseSession()
        if wasSpeaking { onSpeakingChanged?(false) }
    }

    func stop() {
        endCapture()
        stopPlayback()
    }

    private func releaseSession() {
        guard sessionActive, captureEngine == nil, playbackEngine == nil else { return }
        if sharesWakeSession?() != true { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        sessionActive = false
    }
}
