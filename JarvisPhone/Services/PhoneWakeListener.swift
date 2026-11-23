import AVFoundation
import Speech
import UIKit

// The input tap and the recognizer use different queues. Changing requests must never let
// an old tap feed a new turn after the user disables listening.
private final class WakeAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    // ASR partials sometimes stop changing before the speaker has finished. Measure
    // recent input energy too, so that a delayed partial cannot cut off a sentence.
    private var lastVoice: TimeInterval = -.infinity
    private var floorRMS = 0.002
    func latestActivity() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return lastVoice }

    func replace(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = next
        lastVoice = -.infinity
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        if let request {
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var energy = 0.0, count = 0
                for i in stride(from: 0, to: Int(buffer.frameLength), by: 8) {
                    let x = Double(data[i]); energy += x * x; count += 1
                }
                let rms = sqrt(energy / Double(max(1, count)))
                let threshold = max(0.006, floorRMS * 2.8)
                if rms > threshold {
                    lastVoice = ProcessInfo.processInfo.systemUptime
                } else {
                    // Learn background during gaps. Learning from speech raises the
                    // threshold until the end of a quieter sentence disappears.
                    floorRMS += (min(rms, 0.012) - floorRMS) * 0.018
                }
            }
            request.append(buffer)
        }
        lock.unlock()
    }
}

@MainActor final class PhoneWakeListener {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private let input = WakeAudioInput()
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var muteDeadline: Task<Void, Never>?
    private var pendingMute = false
    var onMute: (() -> Void)?
    var isOutputEcho: ((String) -> Bool)?
    private var generation = UUID()
    private var waiting = false
    private var pendingText = ""
    private var lastPartial: TimeInterval = 0
    private var needsNewPhrase = false
    private var greetIfSilent = false
    private var window = WakeConversationWindow()
    private var idleTimer: Task<Void, Never>?
    var onWindowChanged: ((Bool) -> Void)?
    var conversationOpen: Bool { window.phase != .standby }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var lastFailure = Date.distantPast
    private var rapidFailures = 0
    private(set) var paused = false
    var running: Bool { engine != nil }
    var receivingCommand: Bool { waiting || paused }
    var onPrompt: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    func authorize() async throws {
        guard recognizer?.supportsOnDeviceRecognition == true else { throw failure("O reconhecimento local em português não está disponível neste iPhone.") }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw failure("Permita o reconhecimento de fala em Ajustes para ativar Oi Jarvis.") }
        try Task.checkCancellation()
        guard await AVAudioApplication.requestRecordPermission() else { throw failure("Permita o microfone em Ajustes para ativar Oi Jarvis.") }
        try Task.checkCancellation()
    }

    func start() throws {
        if running { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw failure("O reconhecimento local de fala está indisponível.")
        }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let node = engine.inputNode
        do {
            try node.setVoiceProcessingEnabled(true)
            node.isVoiceProcessingAGCEnabled = true
            // The Jarvis reply uses a separate playback engine. Avoid ducking it.
            node.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw failure("O microfone está indisponível.")
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format, block: input.append)
        self.engine = engine
        do {
            engine.prepare()
            try engine.start()
            paused = false
            rapidFailures = 0
            listen()
        } catch { stop(); throw error }
    }

    func setPaused(_ value: Bool) {
        guard running, paused != value else { return }
        paused = value
        clearRecognition()
        idleTimer?.cancel()
        if value { window.pause(at: now) } else { window.resume(at: now) }
        waiting = !value && conversationOpen
        needsNewPhrase = waiting
        greetIfSilent = false
        pendingText = ""
        if !value { armIdleTimer(); onWindowChanged?(waiting) }
        listen() // During output only the local interruption command is accepted.
    }

    func stop(releaseSession: Bool = true) {
        idleTimer?.cancel()
        window = WakeConversationWindow()
        clearRecognition()
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        paused = false
        waiting = false
        needsNewPhrase = false
        greetIfSilent = false
        pendingText = ""
        if releaseSession { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func clearRecognition() {
        generation = UUID()
        muteDeadline?.cancel()
        pendingMute = false
        deadline?.cancel()
        rotation?.cancel()
        input.replace(nil)
        recognition?.cancel()
        recognition = nil
    }

    private func listen() {
        guard running, let recognizer else { return }
        clearRecognition()
        let id = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Oi Jarvis", "Ei Jarvis", "Jarvis muta", "Jarvis", "Spotify", "lanterna", "luz do quarto"]
        input.replace(request)
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            // A pause separates the user's interruption from words picked up from
            // the speaker. Never interpret an arbitrary suffix of a sentence.
            let segments = result?.bestTranscription.segments ?? []
            var start = 0
            for i in segments.indices.dropFirst() where segments[i].timestamp - (segments[i-1].timestamp + segments[i-1].duration) > 0.32 { start = i }
            let latestPhrase = segments[start...].map(\.substring).joined(separator:" ")
            let final = result?.isFinal == true
            let ns = error as NSError?
            let silence = ns?.domain == "kAFAssistantErrorDomain" && ns?.code == 1110
            let failed = error != nil && !silence
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if let text { self.receive(text, latestPhrase: latestPhrase, final: final) }
                guard self.generation == id else { return }
                if final || failed || silence { self.restart(afterFailure: failed) }
            }
        }
        // Speech may end an individual request even while the audio session remains active.
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 52_000_000_000)
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.restart(afterFailure: false)
        }
        if waiting && (greetIfSilent || !pendingText.isEmpty) { scheduleCommand(after: pendingText.isEmpty ? 1.25 : 0.9) }
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        guard case let .listening(until) = window.phase else { return }
        idleTimer = Task { [weak self] in
            let remaining = max(0, until - ProcessInfo.processInfo.systemUptime)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.window.expire(at: self.now)
            guard !self.conversationOpen else { self.armIdleTimer(); return }
            self.waiting = false; self.needsNewPhrase = false; self.greetIfSilent = false; self.pendingText = ""
            self.onWindowChanged?(false)
            self.listen() // Dispose of the previous turn's cumulative transcript.
        }
    }

    func openConversation() {
        guard running, !paused else { return }
        clearRecognition()
        window.listen(at: now); waiting = true; needsNewPhrase = true; greetIfSilent = false; pendingText = ""
        armIdleTimer(); listen(); onPrompt?(); onWindowChanged?(true)
    }

    func endConversation() {
        idleTimer?.cancel(); window = WakeConversationWindow()
        waiting = false; needsNewPhrase = false; greetIfSilent = false; pendingText = ""
        if running && !paused { listen() }
        onWindowChanged?(false)
    }

    func standbyAfterMute() {
        paused = false
        endConversation() // Also discards the previous recognition request and its timers.
    }

    private func restart(afterFailure: Bool) {
        if afterFailure {
            let now = Date()
            rapidFailures = now.timeIntervalSince(lastFailure) < 3 ? rapidFailures + 1 : 1
            lastFailure = now
            if rapidFailures >= 4 {
                stop()
                onFailure?("A escuta local foi interrompida. Ative Oi Jarvis novamente.")
                return
            }
        }
        if pendingMute, !afterFailure { onMute?(); return }
        if waiting, !pendingText.isEmpty { dispatchCommand(); return }
        needsNewPhrase = waiting
        clearRecognition()
        let id = generation
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: afterFailure ? 700_000_000 : 90_000_000)
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.listen()
        }
    }

    private func receive(_ text: String, latestPhrase: String, final: Bool) {
        let control = PhoneVoiceControl.isMute(text) ? text : ((paused || waiting) ? latestPhrase : "")
        if PhoneVoiceControl.isMute(control), isOutputEcho?(control) != true {
            deadline?.cancel()
            if final { onMute?() }
            else if !pendingMute {
                pendingMute = true
                let id = generation
                muteDeadline = Task { [weak self] in
                    try? await Task.sleep(for:.milliseconds(550))
                    guard !Task.isCancelled, let self, self.generation == id, self.pendingMute else { return }
                    self.onMute?()
                }
            }
            return
        }
        pendingMute = false; muteDeadline?.cancel()
        guard !paused else { return }
        if case let .listening(until) = window.phase, now >= until {
            window.expire(at: now); waiting = false; needsNewPhrase = false; pendingText = ""; greetIfSilent = false
            onWindowChanged?(false); listen(); return
        }
        let wake = text.range(of: #"\b(?:oi|ei)[\s,.!?:–—-]+(?:jarvis|jarves|jarvbis)\b"#,
                              options: [.regularExpression, .caseInsensitive, .diacriticInsensitive, .backwards])
        var next: String
        if let wake {
            next = String(text[wake.upperBound...])
            if !waiting { waiting = true; greetIfSilent = true; lastPartial = now; window.listen(at: now); armIdleTimer(); onPrompt?(); scheduleCommand(after: 1.25) }
            needsNewPhrase = false
        } else if waiting && needsNewPhrase {
            next = text
        } else { return }
        next = next.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !next.isEmpty else { return }
        greetIfSilent = false
        if next != pendingText {
            window.listen(at: now); armIdleTimer()
            pendingText = next
            lastPartial = now
            scheduleCommand(after: 0.9)
        }
        if final { dispatchCommand() }
    }

    private func scheduleCommand(after seconds: Double) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.waiting else { return }
            if self.pendingText.isEmpty {
                if self.greetIfSilent {
                    let wait = WakeConversationWindow.endpointDelay(at: self.now, partial: self.lastPartial, voice: self.input.latestActivity())
                    if wait > 0 { self.scheduleCommand(after: wait); return }
                    self.setPaused(true)
                    self.onCommand?("Oi Jarvis")
                    return
                }
                self.waiting = false
                self.needsNewPhrase = false
                self.listen()
            } else {
                let wait = WakeConversationWindow.endpointDelay(at: self.now, partial: self.lastPartial, voice: self.input.latestActivity())
                if wait > 0 { self.scheduleCommand(after: wait) } else { self.dispatchCommand() }
            }
        }
    }

    private func dispatchCommand() {
        guard waiting, !pendingText.isEmpty else { return }
        let text = String(pendingText.prefix(2000))
        setPaused(true)
        onCommand?(text)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "JarvisWake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
