import AppIntents

// Ações individuais expostas diretamente ao app Atalhos. Sem frases de Siri.

struct TurnTorchOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Ligar lanterna"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .torchOn))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct TurnTorchOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Desligar lanterna"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .torchOff))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct ShowVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Abrir controle de volume"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .volume))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct ShowBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Abrir controle de brilho"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .brightness))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Ativar modo reunião"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .meeting))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct EndMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Encerrar modo reunião"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .endMeeting))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct EnableLowPowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Economizar bateria"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .lowPower))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct PauseMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Pausar música no iPhone"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .pause))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct ResumeMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Continuar música no iPhone"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .play))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct NextMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Próxima faixa no iPhone"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .next))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct OpenWhatsAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Abrir WhatsApp"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .whatsapp))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct OpenInstagramIntent: AppIntent {
    static var title: LocalizedStringResource = "Abrir Instagram"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .instagram))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct OpenCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Abrir câmera"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .camera))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct CapturePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Tirar e salvar foto"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .photo))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct ShowLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Mostrar minha localização"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .location))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct CreateReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Criar lembrete"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .reminder))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct CreateLocalNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Criar nota local"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .note))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

struct LockPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Bloquear tela do iPhone"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PhoneController.shared.perform(PhoneCommand(action: .lock))
        PhoneController.shared.report(result)
        return .result(value: result)
    }
}

