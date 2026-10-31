import Foundation

enum PhoneAction: String, CaseIterable, Codable, Identifiable {
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
        case .meeting, .endMeeting, .lowPower, .pause, .play, .next, .lock: return true
        default: return false
        }
    }

    var subtitle: String {
        switch self {
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
