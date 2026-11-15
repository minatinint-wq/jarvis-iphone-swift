import AVFoundation
import Speech
import UIKit

// The input tap and the recognizer use different queues. Changing requests must never let
// an old tap feed a new turn after the user disables listening.
private final class WakeAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replace(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = next
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        request?.append(buffer)
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
    private var generation = UUID()
    private var waiting = false
    private var pendingText = ""
    private var needsNewPhrase = false
    private var greetIfSilent = false
    private var continueAfterGreeting = false
    private var lastFailure = Date.distantPast
    private var rapidFailures = 0
    private(set) var paused = false
    var running: Bool { engine != nil }
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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let node = engine.inputNode
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
        waiting = !value && continueAfterGreeting
        needsNewPhrase = waiting
        continueAfterGreeting = false
        greetIfSilent = false
        pendingText = ""
        if !value { listen() }
    }

    func stop(releaseSession: Bool = true) {
        clearRecognition()
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        paused = false
        waiting = false
        needsNewPhrase = false
        greetIfSilent = false
        continueAfterGreeting = false
        pendingText = ""
        if releaseSession { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func clearRecognition() {
        generation = UUID()
        deadline?.cancel()
        rotation?.cancel()
        input.replace(nil)
        recognition?.cancel()
        recognition = nil
    }

    private func listen() {
        guard running, !paused, let recognizer else { return }
        clearRecognition()
        let id = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Oi Jarvis", "Jarvis"]
        input.replace(request)
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if let text { self.receive(text, final: final) }
                guard self.generation == id else { return }
                if final || failed { self.restart(afterFailure: failed) }
            }
        }
        // Speech may end an individual request even while the audio session remains active.
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 52_000_000_000)
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.restart(afterFailure: false)
        }
        if waiting { scheduleCommand(after: pendingText.isEmpty ? (greetIfSilent ? 1.4 : 7.0) : 0.9) }
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

    private func receive(_ text: String, final: Bool) {
        let wake = text.range(of: #"\boi[\s,.!?:–—-]+jarvis\b"#,
                              options: [.regularExpression, .caseInsensitive, .diacriticInsensitive, .backwards])
        var next: String
        if let wake {
            next = String(text[wake.upperBound...])
            if !waiting { waiting = true; greetIfSilent = true; onPrompt?(); scheduleCommand(after: 1.4) }
            needsNewPhrase = false
        } else if waiting && needsNewPhrase {
            next = text
        } else { return }
        next = next.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !next.isEmpty else { return }
        greetIfSilent = false
        if next != pendingText {
            pendingText = next
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
                    self.setPaused(true)
                    self.continueAfterGreeting = true
                    self.onCommand?("Oi Jarvis")
                    return
                }
                self.waiting = false
                self.needsNewPhrase = false
                self.listen()
            } else { self.dispatchCommand() }
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
