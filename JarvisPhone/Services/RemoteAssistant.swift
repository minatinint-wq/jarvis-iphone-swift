import Foundation
import SwiftUI
import UIKit
import AVFoundation
import ActivityKit

@MainActor final class RemoteAssistant: ObservableObject {
    static let shared = RemoteAssistant()
    @Published var showingFace = false
    @Published private(set) var autonomous = false
    private var idleJob: Task<Void, Never>?
    private var nextRemark = Date.distantFuture
    private var previews = VoiceInbox()
    private var lastBadge: WakeActivityAttributes.ContentState?
    private var pendingVisionUntil: Date?
    private var frameRequest: RearFrame?
    private var liveVisionJob: Task<Void, Never>?
    @Published private(set) var liveVision = false
    private var localSpeechJob: Task<Void, Never>?
    private var replyCache = JarvisReplyCache()
    private var captureReply: String?
    private var capturePCM = Data()
    private static let quickReplies: [String: Data] = {
        guard let file = Bundle.main.url(forResource: "JarvisQuickReplies", withExtension: "json"),
              let data = try? Data(contentsOf: file), let bank = try? JSONDecoder().decode(JarvisQuickReplyBank.self, from: data),
              bank.voice == "a5b93aeddcc948c19ea04f0afe9d178c", bank.sampleRate == 24000 else { return [:] }
        return bank.replies.compactMapValues { text in
            guard let pcm = Data(base64Encoded: text), !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return nil }
            return pcm
        }
    }()

    enum VisionCommand { case once, start, stop }
    static func visionCommand(_ text: String) -> VisionCommand? {
        let words = PhoneVoiceControl.words(text)
            .replacingOccurrences(of: #"^(oi )?(jarvis|jarves|jarvbis) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " por favor$", with: "", options: .regularExpression)
        switch words {
        case "o que estou vendo", "oque estou vendo", "o que eu estou vendo", "o que eu to vendo", "o que to vendo", "o que voce ve", "o que voce esta vendo", "descreva o que estou vendo": return .once
        case "visao ao vivo", "ativar visao ao vivo", "ative a visao ao vivo", "ligar visao ao vivo", "descreva em tempo real": return .start
        case "parar visao", "pare a visao", "parar visao ao vivo", "desligar visao ao vivo", "fechar camera": return .stop
        default: return nil
        }
    }
    private func speakJarvis(_ text: String, append: Bool = true) {
        guard !quietUntilCalled else { return }
        message = text
        if append { add(false, text) }
        if playBundledReply(text) { return }
        if let pcm = replyCache.audio(for: text), playJarvisPCM(pcm) { return }
        localSpeechJob?.cancel()
        guard ready, handsetActions, let sock = ws else {
            _ = playBundledReply("Sem conexão com a voz do Jarvis agora. A resposta está na tela.")
            return
        }
        localSpeechJob = Task { [weak self] in
            guard !Task.isCancelled, let self, !self.quietUntilCalled, self.ws === sock else { return }
            await self.sendHandsetReply(text, sock)
        }
    }
    func speakAutomation(_ text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 1000 else { throw PhoneCommandError.unavailable("Use uma resposta de até mil caracteres.") }
        guard !quietUntilCalled, !busy, !recording, !isSpeaking,
              UIApplication.shared.applicationState == .active || listeningInBackground else {
            throw PhoneCommandError.unavailable("Ative a escuta do Jarvis para falar em segundo plano, ou abra o app.")
        }
        speakJarvis(clean)
    }
    func stopVision() {
        pendingVisionUntil = nil
        liveVisionJob?.cancel()
        liveVisionJob = nil
        liveVision = false
        frameRequest?.cancel()
        frameRequest = nil
    }
    func describeView(continuous: Bool = false) async {
        guard !quietUntilCalled, frameRequest == nil else { return }
        guard active, UIApplication.shared.applicationState == .active else {
            pendingVisionUntil = Date().addingTimeInterval(45)
            speakJarvis("Abra o Jarvis para eu usar a câmera traseira.")
            return
        }
        guard ready, cameraAvailable else { speakJarvis("A visão está indisponível. Confira a conexão com a ponte do PC."); return }
        guard !busy, !recording, studioMode == nil else { return }
        let request = RearFrame()
        frameRequest = request
        defer { if frameRequest === request { frameRequest = nil }; updateWake() }
        wake.setPaused(true)
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard frameRequest === request, active, !quietUntilCalled else { return }
        guard allowed else { stopVision(); speakJarvis("Permita a câmera para o Jarvis nos Ajustes do iPhone."); return }
        guard UIApplication.shared.applicationState == .active else { return }
        message = "Olhando pela câmera traseira…"
        let photo = await request.capture()
        guard frameRequest === request, active, !quietUntilCalled, UIApplication.shared.applicationState == .active else { return }
        guard let photo else { stopVision(); speakJarvis("A câmera traseira não entregou uma imagem. Tente novamente."); return }
        await analyze(photo)
        if continuous && !liveVision && busy {
            liveVision = true
            liveVisionJob = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self, self.active, self.liveVision else { return }
                    if self.ready && self.cameraAvailable && !self.busy && !self.isSpeaking && !self.wake.receivingCommand {
                        await self.describeView()
                    }
                }
            }
        }
    }
    private func resumePendingVision() {
        guard let deadline = pendingVisionUntil, active, ready, UIApplication.shared.applicationState == .active else { return }
        pendingVisionUntil = nil
        guard Date() <= deadline else { return }
        Task { await describeView() }
    }
    private var activity: Activity<WakeActivityAttributes>?
    private var lastPhase = ""
    private var lastCall = Date.distantPast
    private var quietUntilCalled = false
    private var spokenWords = ""
    private var wakeTask: Task<Void, Never>?
    func playbackLevel() -> Double { sound.playbackLevel() }
    func heardCall() {
        quietUntilCalled = false
        spokenWords = ""
        lastCall = Date()
        if active && studioMode == nil { showingFace = true }
        message = "Ouvindo seu pedido…"
        setPhase("Ouvindo seu pedido")
    }
    private func badgeState(_ phase: String) -> WakeActivityAttributes.ContentState {
        let phone = HandsetContext.shared
        let show = UserDefaults.standard.bool(forKey: "jarvis.showLockPreview")
        return .init(phase: phase, steps: phone.steps, stepsDate: phone.stepsDate, battery: phone.battery,
                     preview: show ? phone.preview.map { String($0.text.prefix(100)) } : nil, received: phone.preview?.date)
    }
    func refreshBadge() { setPhase(lastPhase) }
    private func startBadge() {
        guard active, UIApplication.shared.applicationState == .active, activity == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: badgeState("Aguardando “Oi, Jarvis”"), staleDate:nil)
        activity = try? Activity.request(attributes: WakeActivityAttributes(), content: content, pushType:nil)
        for old in Activity<WakeActivityAttributes>.activities where old.id != activity?.id {
            Task { await old.end(nil, dismissalPolicy:.immediate) }
        }
        lastPhase = content.state.phase; lastBadge = content.state
    }
    private func setPhase(_ phase: String) {
        let state = badgeState(phase)
        guard let activity, state != lastBadge else { return }
        lastBadge = state
        lastPhase = phase
        Task { await activity.update(ActivityContent(state:state, staleDate:nil)) }
    }
    private func stopBadge() {
        guard let old = activity else { return }
        activity = nil; lastPhase = ""; lastBadge = nil
        Task { await old.end(nil, dismissalPolicy:.immediate) }
    }
    func setAutonomous(_ enabled: Bool) {
        idleJob?.cancel(); idleJob = nil
        previews = VoiceInbox(); autonomous = enabled && wakeAuthorized && wakeEnabled
        guard autonomous else { return }
        nextRemark = Date().addingTimeInterval(30)
        idleJob = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.autonomousTick()
            }
        }
    }
    @discardableResult func receivePreview(_ text: String) -> Bool {
        guard HandsetContext.shared.remember(text) else { return false }
        if autonomous && !quietUntilCalled { _ = previews.insert(text, now: Date()) }
        return true
    }
    private var canAnnounce: Bool {
        autonomous && !quietUntilCalled && listeningInBackground && !busy && !isSpeaking &&
        !recording && !wakeHandling && !wake.receivingCommand &&
        localRequest == nil && studioMode == nil && Date().timeIntervalSince(lastCall) > 7 &&
        AVAudioSession.sharedInstance().outputVolume > 0
    }
    private func autonomousTick() async {
        let now = Date()
        guard canAnnounce, (8..<22).contains(Calendar.current.component(.hour, from: now)) else { return }
        if let preview = previews.next(now: now) { speakJarvis("Nova notificação. " + preview); return }
        guard now >= nextRemark else { return }
        nextRemark = now.addingTimeInterval(60)
        if let line = await HandsetContext.shared.proactiveNotice(), canAnnounce { speakJarvis(line) }
    }
    struct Line: Identifiable { let id=UUID(); let user:Bool; let text:String }
    @Published var paired = PairingStore.read() != nil
    @Published var ready = false
    @Published var busy = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var wakeEnabled = false
    @Published private(set) var followUp = false
    @Published private(set) var spotifyPhones: [[String: String]] = []
    @Published private(set) var spotifyID = UserDefaults.standard.string(forKey: "jarvis.spotify.phone") ?? ""
    @Published private(set) var spotifyName = UserDefaults.standard.string(forKey: "jarvis.spotify.name") ?? ""
    @Published private(set) var spotifyNotice = ""
    @Published private(set) var spotifyBinding = false
    private var spotifyTimeout: Task<Void, Never>?
    private var allowSpotifyOpen = false
    private var spotifyHandoff: UIBackgroundTaskIdentifier = .invalid
    private var verifyAfterSpotify = false
    private var spotifyInstallation: String {
        if let saved = UserDefaults.standard.string(forKey: "jarvis.spotify.installation"), UUID(uuidString: saved) != nil { return saved }
        // An installer may enroll this individual handset before its first launch.
        // Public builds do not contain an enrollment file.
        let enrolled = Bundle.main.url(forResource:"SpotifyEnrollment",withExtension:"txt")
            .flatMap { try? String(contentsOf:$0, encoding:.utf8) }
            .flatMap { UUID(uuidString:$0.trimmingCharacters(in:.whitespacesAndNewlines)) }
        let id = (enrolled ?? UUID()).uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "jarvis.spotify.installation")
        return id
    }
    private func connectPacket() -> [String:Any] {
        ["type":"connect","nativeAssistant":true,"handsetActions":true,"spotifyPhone":spotifyID,
         "spotifyName":spotifyName,"installationId":spotifyInstallation]
    }
    func selectSpotifyPhone(_ id: String) {
        guard !id.isEmpty, spotifyPhones.contains(where: { $0["id"] == id }) else { return }
        requestSpotify("select", id: id)
    }
    func bindSpotifyPhone() { requestSpotify("bind", mayOpen: true) }
    func listSpotifyPhones() { requestSpotify("list") }
    private func requestSpotify(_ action: String, id: String = "", mayOpen: Bool = false) {
        guard ready, let sock = ws, !spotifyBinding else { return }
        spotifyBinding = true; allowSpotifyOpen = mayOpen
        spotifyNotice = "Procurando este iPhone no Spotify…"
        var packet = connectPacket()
        packet["spotifyBinding"] = ["action":action, "deviceId":id,
                                    "preferredName":spotifyName.isEmpty ? UIDevice.current.name : spotifyName]
        spotifyTimeout?.cancel()
        spotifyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.ws === sock, self.spotifyBinding else { return }
            self.spotifyBinding = false; self.allowSpotifyOpen = false
            self.spotifyNotice = "A ponte não confirmou o vínculo. Toque em verificar para consultar novamente."
        }
        Task { [weak self] in
            guard let self, self.ws === sock else { return }
            do { try await self.send(packet, sock) }
            catch { guard self.ws === sock else { return }; self.spotifyTimeout?.cancel(); self.spotifyBinding = false
                self.allowSpotifyOpen = false; self.spotifyNotice = "A conexão com o PC caiu antes de confirmar o vínculo." }
        }
    }
    func acceptSpotifyStatus(_ o: [String:Any]) {
        let state = o["state"] as? String
        if let rows = o["phones"] as? [[String:Any]] {
            spotifyPhones = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty, let name = row["name"] as? String else { return nil }
                return ["id":id, "name":name]
            }
        }
        if let msg = o["message"] as? String { spotifyNotice = msg }
        let verified = state == "bound" && o["confirmed"] as? Bool == true
        let previouslyLinked = state == "unavailable" && o["saved"] as? Bool == true
        if verified || previouslyLinked, let id = o["deviceId"] as? String, !id.isEmpty,
           let name = o["deviceName"] as? String, !name.isEmpty {
            spotifyID = id; spotifyName = name
            UserDefaults.standard.set(id, forKey:"jarvis.spotify.phone"); UserDefaults.standard.set(name, forKey:"jarvis.spotify.name")
            if verified { verifyAfterSpotify = false }
        }
        if state != nil {
            spotifyTimeout?.cancel(); spotifyBinding = false
        }
        if o["openSpotify"] as? Bool == true && (allowSpotifyOpen || state == nil) && !quietUntilCalled {
            allowSpotifyOpen = false
            showSpotify(forPlayback: (o["completingPlayback"] as? Bool) ?? (state == nil && busy))
        }
        if state != nil { allowSpotifyOpen = false }
    }
    private func continueSpotifyBinding() {
        guard verifyAfterSpotify, active, ready, !spotifyBinding, !quietUntilCalled else { return }
        verifyAfterSpotify = false
        requestSpotify("bind")
    }
    private func endSpotifyHandoff() {
        guard spotifyHandoff != .invalid else { return }
        let id = spotifyHandoff
        spotifyHandoff = .invalid
        UIApplication.shared.endBackgroundTask(id)
        if !active && !listeningInBackground && !busy && ws != nil { drop() }
    }
    func showSpotify(forPlayback: Bool = false) {
        guard active, UIApplication.shared.applicationState == .active, let url = URL(string:"spotify:") else { return }
        verifyAfterSpotify = !forPlayback
        if forPlayback && spotifyHandoff == .invalid {
            spotifyNotice = "Abrindo o Spotify para tocar neste iPhone…"
            spotifyHandoff = UIApplication.shared.beginBackgroundTask(withName: "Spotify no iPhone") { [weak self] in
                Task { @MainActor in self?.endSpotifyHandoff() }
            }
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { Task { @MainActor in self.endSpotifyHandoff(); self.verifyAfterSpotify = false; self.spotifyNotice = "Instale o Spotify neste iPhone e entre na mesma conta vinculada ao Jarvis."; self.message = self.spotifyNotice } }
        }
    }
    @Published var recording = false
    @Published var cameraAvailable = false
    @Published var studioMode: String? { didSet { updateWake() } }
    @Published var spatialPanelResponse: Data?
    @Published var wallARRequest: WallARRequest?
    @Published private(set) var localStudio = false
    @Published private(set) var studioInstrument = StudioInstrument.harp
    @Published var wantsVoice = false
    @Published var cameraRequested = false
    @Published var message = "Conecte ao seu Jarvis."
    @Published var lines: [Line] = []
    @Published var presentedArtwork: UIImage?
    @Published var artwork: UIImage? {
        didSet { presentedArtwork = artwork }
    }
    @Published var display: UIImage?
    private var imageID: String?
    private var receivedImage = Data()
    let origin="https://jarvis-remoto.minatinint.workers.dev"
    private let session: URLSession = { let c=URLSessionConfiguration.ephemeral; c.httpShouldSetCookies=false; c.timeoutIntervalForRequest=20; return URLSession(configuration:c) }()
    private var ws: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var retryJob: Task<Void, Never>?
    private var handshakeTimer: Task<Void, Never>?
    private var micJob: Task<Void, Never>?
    private var micID: UUID?
    private var localRequest: UUID?
    private var retryCount = 0
    private var active = true
    private var suppressAudio = false
    private var handsetActions = false
    private var awaitingHandsetCommand = false
    private let sound = HandsetAudio()
    private let wake = PhoneWakeListener()
    private var openWhenArmed = false
    private var wakePermission: Task<Void, Never>?
    private var wakeResume: Task<Void, Never>?
    @Published private(set) var wakeAuthorized = false
    private var systemInterrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private var wakeHandling = false
    private var wakeSessionCookie: String?
    private var lockedConversation = false
    private var listeningInBackground: Bool { wakeEnabled && wakeAuthorized && wake.running && !systemInterrupted }

    init() {
        HandsetContext.shared.onChange = { [weak self] in self?.refreshBadge() }
        sound.sharesWakeSession = { [weak self] in self?.wake.running == true }
        wake.onPrompt = { [weak self] in self?.heardCall() }
        wake.onMute = { [weak self] in self?.muteUntilCalled() }
        wake.isOutputEcho = { [weak self] phrase in
            guard let self, self.isSpeaking else { return false }
            return (" " + self.spokenWords + " ").contains(" " + PhoneVoiceControl.words(phrase) + " ")
        }
        wake.onWindowChanged = { [weak self] open in
            guard let self else { return }
            self.followUp = open
            if !self.busy && !self.isSpeaking {
                if self.quietUntilCalled {
                    self.setPhase("Em silêncio · aguardando Oi, Jarvis")
                    self.message = "Em silêncio. Diga “Oi, Jarvis” para voltar."
                    return
                }
                self.setPhase(open ? "Ouvindo seu próximo pedido" : "Aguardando “Oi, Jarvis”")
                if self.wake.running { self.message = open ? "Pode continuar falando." : "Aguardando “Oi, Jarvis”." }
            }
        }
        wake.onCommand = { [weak self] text in
            guard let self else { return }
            self.wakeHandling = true
            self.wakeTask = Task { await self.handleWakeCommand(text) }
        }
        wake.onFailure = { [weak self] text in self?.setWakeEnabled(false); self?.message = text }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: value) else { return }
            let flags = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                if kind == .began {
                    self.systemInterrupted = true
                    self.wakeResume?.cancel()
                    self.wake.stop(releaseSession: false)
                } else if kind == .ended {
                    self.systemInterrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume) && self.active { self.updateWake() }
                    else if self.wakeEnabled { self.setWakeEnabled(false); self.message = "Escuta interrompida. Ative Oi Jarvis para continuar." }
                }
            }
        }
        sound.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.isSpeaking = speaking
            self.setPhase(speaking ? "Jarvis está falando" : (self.busy ? "Processando" : (self.wake.conversationOpen ? "Ouvindo seu próximo pedido" : "Aguardando “Oi, Jarvis”")))
            self.updateWake()
            if speaking { self.message = "Jarvis está falando." }
            else if !self.busy && self.message == "Jarvis está falando." { self.message = "Resposta no iPhone." }
        }
        sound.onInterrupted = { [weak self] in
            guard let self else { return }
            self.suppressAudio = true
            if self.micID != nil { self.drop(); self.scheduleReconnect() }
            self.message = "Áudio interrompido pelo iPhone."
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func setWakeEnabled(_ enabled: Bool) {
        wakePermission?.cancel()
        wakeResume?.cancel()
        wakeEnabled = enabled
        wakeAuthorized = false
        wakeSessionCookie = nil
        if !enabled {
            openWhenArmed = false
            UserDefaults.standard.removeObject(forKey:"jarvis.wakeOptIn")
            followUp = false
            setAutonomous(false); stopBadge()
            wake.stop(releaseSession: !isSpeaking)
            if !active { drop() }
            return
        }
        guard active, UIApplication.shared.isProtectedDataAvailable else {
            wakeEnabled = false
            message = "Abra o Jarvis no iPhone desbloqueado para iniciar a escuta."
            return
        }
        wakePermission = Task { [weak self] in
            guard let self else { return }
            do {
                try await wake.authorize()
                guard !Task.isCancelled, wakeEnabled, active else { return }
                wakeAuthorized = true
                UserDefaults.standard.set(true,forKey:"jarvis.wakeOptIn")
                wakeSessionCookie = PairingStore.read()
                startBadge()
                updateWake()
            } catch {
                guard !Task.isCancelled else { return }
                setWakeEnabled(false)
                message = error.localizedDescription
            }
        }
    }

    private func updateWake() {
        wakeResume?.cancel()
        guard wakeEnabled, wakeAuthorized, !systemInterrupted else { return }
        if let mode = studioMode, mode != "wallAR" { wake.stop(releaseSession: !isSpeaking); return }
        guard !busy, !recording, !isSpeaking, !wakeHandling, frameRequest == nil, localRequest == nil else {
            wake.setPaused(true)
            return
        }
        // Starting a microphone session is a foreground operation. Only a live session
        // explicitly started by the user may continue when the screen is locked.
        guard active || wake.running else { return }
        // Leave time for the output route to drain before accepting a new wake phrase.
        wakeResume = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                guard self.frameRequest == nil, !self.busy else { return }
                if self.wake.running { self.wake.setPaused(false) }
                else if self.active && UIApplication.shared.isProtectedDataAvailable { try self.wake.start() }
                if self.openWhenArmed && self.wake.running { self.openWhenArmed = false; self.wake.openConversation() }
            } catch { self.setWakeEnabled(false); self.message = error.localizedDescription }
        }
    }

    private func handleWakeCommand(_ text: String) async {
        defer { if !Task.isCancelled { wakeHandling = false; updateWake() } }
        guard !Task.isCancelled, !quietUntilCalled, wakeEnabled, !systemInterrupted, !busy, !recording, !isSpeaking else { return }
        if active && UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState == .active {
            await say(text)
            return
        }
        guard !Task.isCancelled, !quietUntilCalled, listeningInBackground else { return }
        if let command = Self.visionCommand(text) {
            if command == .stop { stopVision() } else { await describeView() }
            return
        }
        if let reply = await HandsetContext.shared.respond(text, locked: true) {
            guard !Task.isCancelled, !quietUntilCalled, listeningInBackground else { return }
            add(true, text); speakJarvis(reply); return
        }
        let reply = await PhoneLocalKit.resolve(text, readOnly: true)
        guard !Task.isCancelled, !quietUntilCalled, listeningInBackground else { return }
        add(true, text)
        if let reply {
            add(false, reply)
            message = reply
            if playBundledReply(reply) { return }
            speakJarvis(reply, append: false)
            return
        }
        // Wait for a reconnect before sending. Never replay a request after sending it.
        if !ready && paired {
            connect()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !ready, paired, listeningInBackground, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
        }
        guard !Task.isCancelled, !quietUntilCalled, listeningInBackground else { return }
        guard ready, lockedConversation, let sock = ws else {
            message = "A conversa bloqueada precisa da ponte atualizada e do PC online."
            playConnectionNotice()
            return
        }
        if let reply {
            await sendHandsetReply(reply, sock)
        } else {
            beginWait()
            do { try await send(["type":"text", "text":text, "lockedWake":true], sock) }
            catch { lost(sock) }
        }
    }
    func pair(_ code:String) async {
        guard !paired, let trimmed=PhoneMedia.pairingCode(code) else {message="Use o QR ou o código do painel do seu PC.";return}
        do {
            var r=URLRequest(url:URL(string:origin+"/api/login")!); r.httpMethod="POST"
            r.setValue(origin,forHTTPHeaderField:"Origin"); r.setValue("application/json",forHTTPHeaderField:"Content-Type")
            r.httpBody=try JSONEncoder().encode(["code":trimmed])
            let (_,response)=try await session.data(for:r)
            guard let h=response as? HTTPURLResponse,h.statusCode==200,let raw=h.value(forHTTPHeaderField:"Set-Cookie"),
                  let c=HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":raw],for:r.url!).first(where:{$0.name=="__Host-jarvis" && $0.isSecure}) else { message="Pareamento recusado. Confira o código atual no PC."; return }
            try PairingStore.save(c.value); paired=true
            if wakeAuthorized { wakeSessionCookie = c.value }
            connect()
        } catch { message=error.localizedDescription }
    }
    func connect() {
        guard paired, active || listeningInBackground, ws == nil,
              let cookie = wakeSessionCookie ?? PairingStore.read() else { return }
        retryJob?.cancel()
        retryJob = nil
        var r=URLRequest(url:URL(string:origin.replacingOccurrences(of:"https:",with:"wss:")+"/socket")!)
        r.setValue("__Host-jarvis="+cookie,forHTTPHeaderField:"Cookie");r.setValue(origin,forHTTPHeaderField:"Origin")
        let sock=session.webSocketTask(with:r); sock.maximumMessageSize=600_000;ws=sock; sock.resume(); message="Conectando ao PC…"
        watchHandshake(sock)
        reader=Task { [weak self] in
            do { while !Task.isCancelled {
                let event=try await sock.receive(); guard let self,self.ws===sock else {return}
                switch event {
                case .data(let chunk):
                    guard self.ready, self.busy, !self.suppressAudio, !self.recording else { continue }
                    do {
                        try self.sound.enqueue(chunk)
                        if self.captureReply != nil {
                            if self.capturePCM.count + chunk.count <= JarvisReplyCache.maxEntryBytes { self.capturePCM.append(chunk) }
                            else { self.captureReply = nil; self.capturePCM.removeAll() }
                        }
                    }
                    catch {
                        self.suppressAudio = true
                        self.sound.stopPlayback()
                        self.message = error.localizedDescription
                    }
                case .string(let txt):
                    guard let o=(try? JSONSerialization.jsonObject(with:Data(txt.utf8))) as? [String:Any] else { continue }
                    if o["type"] as? String == "pc-status", o["online"] as? Bool == true {
                        self.watchHandshake(sock)
                        try await self.send(self.connectPacket(), sock)
                        continue
                    }
                    await self.event(o)
                @unknown default: break
                }
            }} catch {
                guard let self, self.ws === sock else { return }
                self.lost(sock)
            }
        }
    }

    private func watchHandshake(_ sock: URLSessionWebSocketTask) {
        handshakeTimer?.cancel()
        handshakeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self, self.ws === sock, !self.ready else { return }
            self.lost(sock)
        }
    }

    private func event(_ o:[String:Any]) async {
        if o["phase"] as? String == "spatial-panel" {
            spatialPanelResponse=try? JSONSerialization.data(withJSONObject:o);return
        }
        if quietUntilCalled, let type = o["type"] as? String, !["pc-status","status"].contains(type) {
            if ["tool-status","input-status"].contains(type), o["phase"] as? String == "spotify-phone" { acceptSpotifyStatus(o) }
            return
        }
        switch o["type"] as? String {
        case "pc-status":
            if o["online"] as? Bool == false {
                handshakeTimer?.cancel()
                ready = false
                handsetActions = false
                studioWentOffline()
                cameraAvailable = false
                finishWait()
                abortMic()
                message = "O PC está offline."
            }
        case "status":
            handshakeTimer?.cancel()
            ready = o["connected"] as? Bool == true
            lockedConversation = ready && o["backend"] as? String == "iphone" && o["lockedConversation"] as? Bool == true
            if let enabled = o["handsetActions"] as? Bool { handsetActions = ready && enabled }
            cameraAvailable = ready && o["phoneCamera"] as? Bool == true
            if !busy && !recording { message = quietUntilCalled ? "Em silêncio. Diga “Oi, Jarvis” para voltar." : o["message"] as? String ?? "" }
            if ready {
                resumePendingVision()
                retryCount = 0
                continueSpotifyBinding()
                if wantsVoice && active { wantsVoice = false; startListening() }
            } else {
                drop()
                message = o["message"] as? String ?? "O Jarvis está offline."
                scheduleReconnect()
            }
        case "transcript":
            if let t = o["text"] as? String { add(o["role"] as? String == "user", t) }
        case "tool-status","input-status":
            if o["phase"] as? String == "spotify-phone" {
                acceptSpotifyStatus(o)
            }
            if let t = o["message"] as? String, !recording || o["phase"] as? String != "receiving" { message = t }
            if o["phase"] as? String == "handset-command", let text = o["text"] as? String,
               text.count <= 2000, active, ready, handsetActions, awaitingHandsetCommand, let sock = ws {
                awaitingHandsetCommand = false
                let readOnly = !UIApplication.shared.isProtectedDataAvailable || UIApplication.shared.applicationState != .active
                let reply = await PhoneLocalKit.resolve(text, readOnly: readOnly) ?? "Não reconheci esse comando do iPhone."
                guard ws === sock, active else { return }
                add(false, reply)
                if playBundledReply(reply) { finishWait() } else { await sendHandsetReply(reply, sock) }
            }
            if o["phase"] as? String == "retry" { finishWait() }
            if o["phase"] as? String == "open-studio", let mod = o["mode"] as? String,
               ["sketch","music","libras","translate"].contains(mod), active { finishWait(); openStudio(mod, instrument: StudioInstrument(rawValue:o["instrument"] as? String ?? "") ?? .harp) }
            if o["phase"] as? String == "open-phone-camera", active { finishWait(); Task { await describeView() } }
        case "display":
            if o["kind"] as? String == "image-part" {
                guard let id=o["id"] as? String, let offset=o["offset"] as? Int, let total=o["total"] as? Int,
                      (1...1_048_576).contains(total),let part=o["part"] as? String,let bytes=Data(base64Encoded:part),
                      !bytes.isEmpty, bytes.count<=240000 else { return }
                if offset == 0 { imageID=id; receivedImage.removeAll() }
                guard imageID==id, offset==receivedImage.count, offset+bytes.count<=total else {return}
                receivedImage.append(bytes)
                if receivedImage.count==total { if let image=UIImage(data:receivedImage){artwork=image};receivedImage.removeAll();imageID=nil }
                return
            }
            if let s=o["image"] as? String,let cut=s.firstIndex(of:","),s.hasPrefix("data:image/"),let d=Data(base64Encoded:String(s[s.index(after:cut)...])),let image=UIImage(data:d) {
                if o["kind"] as? String=="generated" {artwork=image} else {display=image}
            }
        case "voice-error": captureReply = nil; capturePCM.removeAll(); message=o["text"] as? String ?? "O pedido falhou.";let speakFailure = !active && listeningInBackground && busy;finishWait();if speakFailure { playConnectionNotice() }
        case "interrupted":
            captureReply = nil; capturePCM.removeAll()
            sound.stopPlayback()
        case "turn-complete":
            if let text = captureReply { replyCache.insert(capturePCM, for: text) }
            captureReply = nil; capturePCM.removeAll()
            finishWait()
            sound.finishPlayback()
            if !isSpeaking && ["Jarvis está falando.", "Aguardando o Jarvis…"].contains(message) {
                message = "Resposta no iPhone."
            }
        default: break
        }
    }
    func add(_ user:Bool,_ text:String) {
        if !user { spokenWords = PhoneVoiceControl.words(text) }
        lines.append(Line(user:user,text:text));if lines.count>60 {lines.removeFirst()}
    }
    private func send(_ o:[String:Any],_ sock:URLSessionWebSocketTask) async throws {try await sock.send(.string(String(decoding:try JSONSerialization.data(withJSONObject:o),as:UTF8.self)))}
    func requestSpatialSpotify(_ job: [String:Any]) {
        guard ready, active, let sock=ws else {
            spatialPanelResponse=try? JSONSerialization.data(withJSONObject:["requestId":job["requestId"] ?? "","message":"Conecte o iPhone à ponte do Jarvis para consultar o Spotify."])
            return
        }
        var packet=connectPacket()
        packet["spatialPanel"]=job
        Task {
            do { try await send(packet,sock) }
            catch { spatialPanelResponse=try? JSONSerialization.data(withJSONObject:["requestId":job["requestId"] ?? "","message":"A ponte desconectou antes de confirmar."]) }
        }
    }
    func runSpatialCommand(_ text: String) async {
        quietUntilCalled=false
        let value=PhoneIntentPhrases.normalized(text)
        if value.contains("vendo") || value.contains("visao continua") || value.contains("visao ao vivo") || value.contains("gere uma imagem") { studioMode=nil;await Task.yield() }
        await say(text,fromSpatialPanel:true)
    }
    func say(_ text:String, fromSpatialPanel: Bool = false) async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if PhoneVoiceControl.isMute(value) { muteUntilCalled(); return }
        guard !quietUntilCalled else { message = "Em silêncio. Diga “Oi, Jarvis”."; return }
        guard active, !value.isEmpty, value.count <= 2000, !busy, !recording, localRequest == nil else { return }
        if !fromSpatialPanel, let command = WallARCommand.parse(value, inStudio:studioMode == "wallAR") {
            add(true,value)
            if command == .close { studioMode = nil; wallARRequest = nil; message = "Modo AR fechado."; return }
            if studioMode == "wallAR" || openStudio("wallAR") {
                wallARRequest = WallARRequest(command:command)
            }
            return
        }
        if !fromSpatialPanel, studioMode == "wallAR", WallARCommand.needsInterpretation(value) {
            add(true,value)
            wallARRequest=WallARRequest(command:.navigate(value))
            return
        }
        if let command = Self.visionCommand(value) {
            switch command {
            case .stop: stopVision(); message = "Visão encerrada."
            case .start: await describeView(continuous: true)
            case .once: await describeView()
            }
            return
        }
        if Self.isSpotifyBindingCommand(value) {
            add(true, value)
            guard ready else { message = "Conecte o iPhone ao Jarvis do PC para vincular o Spotify."; add(false, message); return }
            bindSpotifyPhone()
            return
        }
        let request = UUID()
        localRequest = request
        wake.setPaused(true)
        defer { updateWake() }
        if let mode = PhoneLocalKit.studio(for: value) {
            localRequest = nil
            add(true, value)
            if openStudio(mode, instrument: PhoneLocalKit.instrument(for:value)) {
                let reply = ["music":"Cordas no ar abertas.","libras":"Libras aberto.","translate":"Tradutor pela câmera aberto."][mode] ?? "Caderno de desenho aberto."
                add(false, reply)
                message = reply
            }
            return
        }
        let originalSocket = ws
        if PhoneLocalKit.torchAction(value) != nil { stopVision() }
        if let reply = await HandsetContext.shared.respond(value, locked: !UIApplication.shared.isProtectedDataAvailable) {
            guard localRequest == request else { return }
            localRequest = nil
            add(true, value); speakJarvis(reply); return
        }
        let reply = await PhoneLocalKit.resolve(value)
        guard localRequest == request else { return }
        localRequest = nil
        if let reply {
            add(true, value)
            add(false, reply)
            message = reply
            if playBundledReply(reply) { return }
            speakJarvis(reply, append: false)
            return
        }
        guard ready, let sock = ws, sock === originalSocket else {
            message = "Conecte ao PC para este pedido."
            return
        }
        beginWait()
        add(true, value)
        do { try await send(["type":"text", "text":value], sock) } catch { lost(sock) }
    }

    static func isSpotifyBindingCommand(_ value: String) -> Bool {
        let s = PhoneVoiceControl.words(value)
        return s.range(of:#"^(?:(?:oi )?jarvis )?(?:vincula|vincule|vincular|conecta|conecte|conectar|configurar|configura|configure|parear) (?:(?:o |meu )?spotify(?: (?:aqui|(?:a|ao|do|no|neste|nesse|com|com o) (?:meu |este |esse )?(?:iphone|celular|telefone|dispositivo)))?|(?:o |meu |este |esse )?(?:iphone|dispositivo|celular)(?: direto)? (?:ao|no|com o) spotify)$"#, options:.regularExpression) != nil
    }

    @discardableResult func openStudio(_ mode: String, instrument: StudioInstrument = .harp) -> Bool {
        guard active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              !busy, !recording, ["sketch","music","libras","translate","wallAR"].contains(mode) else { return false }
        guard ready || mode != "libras" else { message = "Conecte ao PC para abrir Libras."; return false }
        stopVision()
        showingFace = false; sound.stopPlayback()
        localStudio = !ready
        studioInstrument = instrument
        studioMode = mode
        return true
    }

    func wallARFeedback(_ text: String) {
        message = text
        guard studioMode == "wallAR", !quietUntilCalled, !busy, !isSpeaking else { return }
        speakJarvis(text)
    }

    private func studioWentOffline() {
        if studioMode == "libras" { studioMode = nil }
        else if studioMode != nil { localStudio = true }
    }

    private func playBundledReply(_ reply: String) -> Bool {
        guard !quietUntilCalled else { return false }
        let name: String
        switch reply {
        case PhoneLocalKit.greeting: name = "jarvis-greeting"
        case Self.connectionNotice: name = "jarvis-connection"
        case "Lanterna ligada.": name = "jarvis-torch-on"
        case "Lanterna desligada.": name = "jarvis-torch-off"
        default:
            guard let pcm = Self.quickReplies[reply] else { return false }
            return playJarvisPCM(pcm)
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pcm"),
              let pcm = try? Data(contentsOf: url), !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return false }
        return playJarvisPCM(pcm)
    }

    private func playJarvisPCM(_ pcm: Data) -> Bool {
        guard !quietUntilCalled else { return false }
        wakeResume?.cancel()
        wake.setPaused(true)
        sound.stopPlayback()
        do {
            for at in stride(from: 0, to: pcm.count, by: 8192) {
                try sound.enqueue(pcm.subdata(in: at..<min(at + 8192, pcm.count)))
            }
            sound.finishPlayback()
            return true
        } catch {
            sound.stopPlayback()
            message = error.localizedDescription
            return false
        }
    }

    private func sendHandsetReply(_ reply: String, _ sock: URLSessionWebSocketTask) async {
        guard !quietUntilCalled, ws === sock else { return }
        spokenWords = PhoneVoiceControl.words(reply)
        beginWait()
        captureReply = reply; capturePCM.removeAll(keepingCapacity: true)
        do { try await send(["type":"text", "handsetResult":true, "text":reply], sock) } catch { lost(sock) }
    }

    private static let connectionNotice = "Não consegui conversar com o seu PC agora. Confira a conexão do Jarvis."

    private func playConnectionNotice() {
        _ = playBundledReply(Self.connectionNotice)
    }

    func activate() {
        wantsVoice = true
        guard active else { return }
        if ready { wantsVoice = false; startListening() } else { connect() }
    }

    func endConversation() { openWhenArmed = false; wake.endConversation() }

    private func muteUntilCalled() {
        HandsetContext.shared.cancelPending()
        stopVision()
        localSpeechJob?.cancel(); localSpeechJob = nil
        captureReply = nil; capturePCM.removeAll()
        let hadRemoteTurn = busy
        quietUntilCalled = true
        openWhenArmed = false; wantsVoice = false
        wakeTask?.cancel(); wakeTask = nil; wakeHandling = false
        localRequest = nil; awaitingHandsetCommand = false
        previews = VoiceInbox(); nextRemark = Date().addingTimeInterval(1200)
        suppressAudio = true; spokenWords = ""
        wake.standbyAfterMute()
        sound.stopPlayback(); finishWait()
        // The stream is untagged PCM. Isolate a cancelled turn on its old socket
        // so a delayed packet can never play after the next wake.
        if hadRemoteTurn { drop(); connect() }
        showingFace = false
        setPhase("Em silêncio · aguardando Oi, Jarvis")
        message = wake.running ? "Em silêncio. Diga “Oi, Jarvis” para voltar." : "Em silêncio. Ative Oi, Jarvis para chamar por voz."
    }

    func startListening() {
        guard active, !busy, localRequest == nil else { return }
        quietUntilCalled = false
        openWhenArmed = true
        if !wakeEnabled { setWakeEnabled(true) } else { updateWake() }
    }

    func analyze(_ photo:UIImage) async {
        guard let sock=ws,ready,!busy,cameraAvailable,!recording,localRequest == nil else {message="A análise por câmera ainda não está disponível nesta conexão.";return}
        let length=max(photo.size.width,photo.size.height)
        guard length>0 else {return}
        let ratio=min(1,640/length),size=CGSize(width:max(1,photo.size.width*ratio),height:max(1,photo.size.height*ratio))
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        let resized=UIGraphicsImageRenderer(size:size,format:format).image{_ in photo.draw(in:CGRect(origin:.zero,size:size))}
        for q in [0.75,0.55,0.38,0.22] {
            guard let bytes=resized.jpegData(compressionQuality:q),let packet=PhoneMedia.cameraPacket(bytes) else {continue}
            beginWait();add(true,"Analise esta foto da câmera.");do{try await sock.send(.data(packet))}catch{lost(sock)};return
        };message="A imagem excedeu o tamanho para análise."
    }
    private func beginWait() {
        captureReply = nil; capturePCM.removeAll()
        setPhase("Processando")
        wakeResume?.cancel()
        wake.setPaused(true)
        sound.stopPlayback()
        suppressAudio = false
        busy = true
        message = "Aguardando o Jarvis…"
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 245_000_000_000)
            guard !Task.isCancelled, let self, self.busy else { return }
            self.drop()
            self.message = "O pedido demorou. Confira no PC. Nenhum pedido foi repetido."
            self.scheduleReconnect()
        }
    }

    private func finishWait() { defer { endSpotifyHandoff() }; watchdog?.cancel(); watchdog = nil; busy = false; awaitingHandsetCommand = false; if !isSpeaking { setPhase(wake.conversationOpen ? "Ouvindo seu próximo pedido" : "Aguardando “Oi, Jarvis”") }; updateWake() }

    private func abortMic() {
        micID = nil
        awaitingHandsetCommand = false
        micJob?.cancel()
        micJob = nil
        recording = false
        sound.stop()
        updateWake()
    }

    private func lost(_ sock: URLSessionWebSocketTask) {
        guard ws === sock else { return }
        let closeCode = sock.closeCode.rawValue
        let expired = closeCode == 4003 || (sock.response as? HTTPURLResponse)?.statusCode == 401
        drop()
        if expired {
            wakeSessionCookie = nil
            PairingStore.remove()
            paired = false
            wantsVoice = false
            message = "Sessão expirada. Conecte novamente pelo código do PC."
        } else if closeCode == 4001 {
            wantsVoice = false
            message = "A conexão foi aberta em outro dispositivo. Toque em Reconectar para usar este iPhone."
        } else {
            message = "Recuperando a conexão. Nenhum pedido foi repetido."
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard paired, active || listeningInBackground, ws == nil, retryJob == nil else { return }
        let delay = UInt64(1 << min(4, retryCount))
        retryCount = min(4, retryCount + 1)
        retryJob = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryJob = nil
            self.connect()
        }
    }

    func drop() {
        localSpeechJob?.cancel(); captureReply = nil; capturePCM.removeAll()
        stopVision()
        spotifyTimeout?.cancel(); spotifyBinding = false; allowSpotifyOpen = false
        let old = ws
        ws = nil
        retryJob?.cancel()
        retryJob = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        reader?.cancel()
        reader = nil
        old?.cancel(with: .goingAway, reason: nil)
        imageID = nil
        receivedImage.removeAll()
        finishWait()
        abortMic()
        ready = false
        lockedConversation = false
        handsetActions = false
        studioWentOffline()
        cameraAvailable = false
    }

    func foreground(_ yes: Bool) {
        active = yes
        if yes {
            if !wakeEnabled && UserDefaults.standard.bool(forKey:"jarvis.wakeOptIn") { setWakeEnabled(true) }
            if wakeEnabled, wake.conversationOpen, studioMode == nil { showingFace = true }
            connect()
            continueSpotifyBinding()
            resumePendingVision()
            if ready && wantsVoice { activate() }
            updateWake()
        } else {
            stopVision()
            wantsVoice = false
            HandsetContext.shared.cancelPending()
            localRequest = nil
            if wakeEnabled && !wakeAuthorized { setWakeEnabled(false) }
            if (!listeningInBackground && spotifyHandoff == .invalid) || recording { drop() }
            updateWake()
        }
    }

    func logout() {
        HandsetContext.shared.cancelPending(); HandsetContext.shared.clearPreview()
        spotifyID = ""; spotifyName = ""; spotifyNotice = ""; spotifyPhones = []; verifyAfterSpotify = false
        for key in ["jarvis.spotify.phone", "jarvis.spotify.name", "jarvis.spotify.installation"] { UserDefaults.standard.removeObject(forKey:key) }
        setWakeEnabled(false)
        studioMode = nil
        cameraRequested = false
        localRequest = nil
        drop()
        PairingStore.remove()
        paired = false
        wantsVoice = false
        lines = []
        artwork = nil
        display = nil
        message = "Desconectado."
    }
}
