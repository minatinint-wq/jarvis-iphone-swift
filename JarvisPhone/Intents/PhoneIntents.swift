import AppIntents
import UIKit

struct JarvisDescribeView: AppIntent {
    static var title: LocalizedStringResource = "O que estou vendo?"
    static var description = IntentDescription("Abre o Jarvis e descreve uma imagem da câmera traseira.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        let assistant = RemoteAssistant.shared
        assistant.connect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while (!assistant.ready || UIApplication.shared.applicationState != .active), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        await assistant.describeView()
        return .result()
    }
}

struct JarvisAnnounceNotification: AppIntent {
    static var title: LocalizedStringResource = "Anunciar notificação no Jarvis"
    static var description = IntentDescription("Lê a prévia no iPhone se o modo autônomo já estiver ativo. Não abre o app nem executa o texto como comando.")
    static var openAppWhenRun: Bool = false
    @Parameter(title:"Prévia") var preview: String
    @MainActor func perform() async throws -> some IntentResult {
        RemoteAssistant.shared.receivePreview(preview)
        return .result()
    }
}

enum PhoneActionParameter: String, AppEnum {
    case torchOn = "lanterna_ligar", torchOff = "lanterna_desligar"
    case volume, brightness = "brilho", battery = "bateria"
    case meeting = "reuniao", endMeeting = "encerrar_reuniao", lowPower = "economizar"
    case pause = "pausar", play = "continuar", next = "proxima"
    case whatsapp, instagram, camera, photo = "foto"
    case location = "localizacao", reminder = "lembrete", note = "anotar", lock = "bloquear"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Ação do iPhone"
    static var caseDisplayRepresentations: [PhoneActionParameter: DisplayRepresentation] = [
        .torchOn: "Ligar lanterna", .torchOff: "Desligar lanterna",
        .volume: "Volume", .brightness: "Brilho da tela", .battery: "Bateria",
        .meeting: "Modo reunião", .endMeeting: "Encerrar reunião", .lowPower: "Economizar bateria",
        .pause: "Pausar música", .play: "Continuar música", .next: "Próxima faixa",
        .whatsapp: "Abrir WhatsApp", .instagram: "Abrir Instagram", .camera: "Câmera",
        .photo: "Tirar e salvar foto", .location: "Minha localização",
        .reminder: "Criar lembrete", .note: "Anotar", .lock: "Bloquear tela"
    ]
}

struct ExecutePhoneActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Executar ação no iPhone"
    static var description = IntentDescription("Executa um controle do JARVIS XLV. Algumas ações abrem uma tela para você concluir.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Ação") var action: PhoneActionParameter
    @Parameter(title: "Porcentagem (apenas volume ou brilho)") var percentage: Double?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let nativeAction = PhoneAction(rawValue: action.rawValue) else { throw PhoneCommandError.unknownAction }
        let command = try PhoneCommand(action: nativeAction, percentage: percentage)
        let result = try await PhoneController.shared.perform(command)
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct SetPhoneBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Ajustar brilho do iPhone"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Porcentagem", inclusiveRange: (0, 100)) var percentage: Double

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .brightness, percentage: percentage))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct PhoneBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Consultar bateria do iPhone"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { throw PhoneCommandError.unavailable("Bateria indisponível neste dispositivo.") }
        return .result(value: Int((level * 100).rounded()))
    }
}

// AppIntents aparecem como ações no app Atalhos após instalar e abrir o app.
// Não há AppShortcutsProvider, frases de ativação nem integração de voz com Siri.
