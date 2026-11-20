import Foundation

enum PhoneAction: String, CaseIterable, Codable, Identifiable {
    case wallet = "carteira", wifiOn = "wifi_ligar", wifiOff = "wifi_desligar"
    case bluetoothOn = "bluetooth_ligar", bluetoothOff = "bluetooth_desligar"
    case cellularOn = "dados_ligar", cellularOff = "dados_desligar"
    case rotationLock = "rotacao_bloquear", rotationUnlock = "rotacao_liberar"
    case lowPowerOff = "economia_desligar", shortcutCheck = "verificar_atalho"
    case torchOn = "lanterna_ligar"
    case torchOff = "lanterna_desligar"
    case volume, brightness = "brilho", battery = "bateria"
    case meeting = "reuniao", endMeeting = "encerrar_reuniao", lowPower = "economizar"
    case pause = "pausar", play = "continuar", next = "proxima"
    case whatsapp, instagram, camera = "camera", photo = "foto"
    case location = "localizacao", reminder = "lembrete", note = "anotar", lock = "bloquear"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallet: return "Abrir Wallet"
        case .wifiOn: return "Ligar Wi-Fi"
        case .wifiOff: return "Desligar Wi-Fi"
        case .bluetoothOn: return "Ligar Bluetooth"
        case .bluetoothOff: return "Desligar Bluetooth"
        case .cellularOn: return "Ligar dados móveis"
        case .cellularOff: return "Desligar dados móveis"
        case .rotationLock: return "Travar rotação"
        case .rotationUnlock: return "Liberar rotação"
        case .lowPowerOff: return "Desativar economia"
        case .shortcutCheck: return "Testar atalho"
        case .torchOn: return "Ligar lanterna"
        case .torchOff: return "Desligar lanterna"
        case .volume: return "Volume"
        case .brightness: return "Brilho da tela"
        case .battery: return "Bateria"
        case .meeting: return "Modo reunião"
        case .endMeeting: return "Encerrar reunião"
        case .lowPower: return "Economizar bateria"
        case .pause: return "Pausar música"
        case .play: return "Continuar música"
        case .next: return "Próxima faixa"
        case .whatsapp: return "WhatsApp"
        case .instagram: return "Instagram"
        case .camera: return "Câmera"
        case .photo: return "Tirar e salvar foto"
        case .location: return "Minha localização"
        case .reminder: return "Criar lembrete"
        case .note: return "Anotar"
        case .lock: return "Bloquear tela"
        }
    }

    var symbol: String {
        switch self {
        case .wallet: return "wallet.pass"
        case .wifiOn: return "wifi"
        case .wifiOff: return "wifi.slash"
        case .bluetoothOn: return "antenna.radiowaves.left.and.right"
        case .bluetoothOff: return "antenna.radiowaves.left.and.right.slash"
        case .cellularOn: return "antenna.radiowaves.left.and.right"
        case .cellularOff: return "antenna.radiowaves.left.and.right.slash"
        case .rotationLock: return "lock.rotation"
        case .rotationUnlock: return "rotate.right"
        case .lowPowerOff: return "battery.100percent"
        case .shortcutCheck: return "checkmark.shield"
        case .torchOn: return "flashlight.on.fill"
        case .torchOff: return "flashlight.off.fill"
        case .volume: return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .battery: return "battery.100percent"
        case .meeting: return "moon.fill"
        case .endMeeting: return "bell.fill"
        case .lowPower: return "leaf.fill"
        case .pause: return "pause.fill"
        case .play: return "play.fill"
        case .next: return "forward.end.fill"
        case .whatsapp: return "message.fill"
        case .instagram: return "camera.aperture"
        case .camera, .photo: return "camera.fill"
        case .location: return "location.fill"
        case .reminder: return "checklist"
        case .note: return "square.and.pencil"
        case .lock: return "lock.fill"
        }
    }

    var usesSystemShortcut: Bool {
        switch self {
        case .meeting, .endMeeting, .lowPower, .pause, .play, .next, .lock, .wallet, .wifiOn, .wifiOff, .bluetoothOn, .bluetoothOff, .cellularOn, .cellularOff, .rotationLock, .rotationUnlock, .lowPowerOff, .shortcutCheck: return true
        default: return false
        }
    }

    var subtitle: String {
        switch self {
        case .wallet: return "Abre a carteira; o pagamento exige sua autenticação"
        case .wifiOn: return "Executa no próprio iPhone"
        case .wifiOff: return "Pode interromper a conexão com a ponte"
        case .bluetoothOn: return "Conectar acessórios"
        case .bluetoothOff: return "Pode desconectar seus fones"
        case .cellularOn: return "Usa o plano de dados do iPhone"
        case .cellularOff: return "Pode interromper a conexão com a ponte"
        case .rotationLock: return "Manter a orientação da tela"
        case .rotationUnlock: return "Permitir girar a tela"
        case .lowPowerOff: return "Desativar o Modo Pouca Energia"
        case .shortcutCheck: return "Confirma a versão instalada do JARVIS Sistema"
        case .volume: return "Controle de volume do iPhone"
        case .meeting: return "Não Perturbe e mídia em 0%"
        case .endMeeting: return "Não Perturbe desligado; mídia em 50%"
        case .lowPower: return "Pouca Energia e brilho em 25%"
        case .photo: return "Capture uma foto e salve em Fotos"
        case .note: return "Nota local, com opção de compartilhar"
        case .reminder: return "Salvar no app Lembretes"
        default: return usesSystemShortcut ? "Executa pelo app Atalhos" : "Controle local"
        }
    }
}

enum PhoneCommandError: LocalizedError {
    case invalidURL, unknownAction, invalidPercentage, unexpectedPercentage
    case unavailable(String), permission(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Link de comando inválido."
        case .unknownAction: return "Essa ação não faz parte dos controles do iPhone."
        case .invalidPercentage: return "Informe um número entre 0 e 100."
        case .unexpectedPercentage: return "Essa ação não recebe porcentagem."
        case .unavailable(let message), .permission(let message): return message
        }
    }
}

struct PhoneCommand: Equatable {
    let action: PhoneAction
    let percentage: Double?

    init(action: PhoneAction, percentage: Double? = nil) throws {
        if let percentage {
            guard percentage.isFinite, (0...100).contains(percentage) else {
                throw PhoneCommandError.invalidPercentage
            }
            guard action == .volume || action == .brightness else {
                throw PhoneCommandError.unexpectedPercentage
            }
        }
        self.action = action
        self.percentage = percentage
    }

    static func decode(_ url: URL) throws -> PhoneCommand {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "jarvisiphone", parts.host == "command",
              parts.path.isEmpty || parts.path == "/", parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw PhoneCommandError.invalidURL
        }
        let items = parts.queryItems ?? []
        guard items.allSatisfy({ ["action", "value"].contains($0.name) }),
              items.filter({ $0.name == "action" }).count == 1,
              items.filter({ $0.name == "value" }).count <= 1 else {
            throw PhoneCommandError.invalidURL
        }
        guard let raw = items.first(where: { $0.name == "action" })?.value,
              let action = PhoneAction(rawValue: raw) else {
            throw PhoneCommandError.unknownAction
        }
        var percentage: Double?
        if let item = items.first(where: { $0.name == "value" }) {
            guard let text = item.value, let value = Double(text) else {
                throw PhoneCommandError.invalidPercentage
            }
            percentage = value
        }
        return try PhoneCommand(action: action, percentage: percentage)
    }

    var systemShortcutURL: URL {
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "run-shortcut"
        let payload = action.rawValue + (percentage.map { "|\($0)" } ?? "")
        parts.queryItems = [
            URLQueryItem(name: "name", value: "JARVIS Sistema"),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payload)
        ]
        return parts.url!
    }
}

// Exact, local commands only. Quoted requests, negations and compound requests stay with the assistant.
enum PhoneSystemVoice {
    static func action(_ input: String) -> PhoneAction? {
        var text = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        text = text.replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression).split(separator: " ").joined(separator: " ")
        text = text.replacingOccurrences(of: #"^(?:(?:oi|ei) )?jarvis "#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #" por favor$"#, with: "", options: .regularExpression)
        let on = #"(?:liga|ligue|ligar|ative|ativar|ativa) "#
        let off = #"(?:desliga|desligue|desligar|desative|desativar|desativa) "#
        let patterns: [(String,PhoneAction)] = [
            (#"(?:pagar|quero pagar|(?:abra|abre|abrir) (?:a |o )?(?:wallet|carteira))"#, .wallet),
            (on + #"(?:o )?wi ?fi"#, .wifiOn), (off + #"(?:o )?wi ?fi"#, .wifiOff),
            (on + #"(?:o )?bluetooth"#, .bluetoothOn), (off + #"(?:o )?bluetooth"#, .bluetoothOff),
            (on + #"(?:os )?dados moveis"#, .cellularOn), (off + #"(?:os )?dados moveis"#, .cellularOff),
            (#"(?:trave|trava|bloqueie|bloquear) (?:a )?rotacao"#, .rotationLock),
            (#"(?:libere|libera|desbloqueie|desbloquear) (?:a )?rotacao"#, .rotationUnlock),
            (#"(?:modo reuniao|ative o modo reuniao|modo concentracao)"#, .meeting),
            (#"(?:encerre|encerrar|desative|sair do) (?:o )?(?:modo )?reuniao"#, .endMeeting),
            (#"(?:economizar bateria|economize bateria|ative (?:o )?modo (?:pouca energia|economia))"#, .lowPower),
            (off + #"(?:o )?(?:modo )?(?:pouca energia|economia(?: de bateria)?)"#, .lowPowerOff),
            (#"(?:bloqueie|bloquear|trave) (?:a tela|o iphone|o celular)"#, .lock),
            (#"(?:teste|testar|verifique|verificar) (?:o )?(?:atalho|atalhos|jarvis sistema)"#, .shortcutCheck),
            (#"(?:abra|abre|abrir) (?:o )?whatsapp"#, .whatsapp),
            (#"(?:abra|abre|abrir) (?:o )?instagram"#, .instagram)
        ]
        return patterns.first { text.range(of: "^(?:" + $0.0 + ")$", options: .regularExpression) != nil }?.1
    }
}

enum PhoneShortcutReceipt {
    static let version = "JARVIS_SISTEMA_14"
    static func probeURL(token: String) -> URL {
        var callback = URLComponents()
        callback.scheme = "jarvisiphone"; callback.host = "shortcut-receipt"
        callback.queryItems = [URLQueryItem(name: "token", value: token)]
        var target = URLComponents()
        target.scheme = "shortcuts"; target.host = "x-callback-url"; target.path = "/run-shortcut"
        target.queryItems = [URLQueryItem(name: "name", value: "JARVIS Sistema"),
                             URLQueryItem(name: "input", value: "text"),
                             URLQueryItem(name: "text", value: "verificar_atalho"),
                             URLQueryItem(name: "x-success", value: callback.url!.absoluteString)]
        return target.url!
    }
    static func accepts(_ url: URL, token: String, expires: Date, now: Date = Date()) -> Bool {
        guard now < expires, let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              p.scheme == "jarvisiphone", p.host == "shortcut-receipt", p.path.isEmpty,
              p.user == nil, p.password == nil, p.port == nil, p.fragment == nil else { return false }
        let q = p.queryItems ?? []
        return q.count == 2 && q.filter { $0.name == "token" && $0.value == token }.count == 1
            && q.filter { $0.name == "result" && $0.value == version }.count == 1
    }
}
