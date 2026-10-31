import AVFoundation
import Combine
import EventKit
import MapKit
import Photos
import UIKit

enum PhoneSheet: String, Identifiable {
    case volume, brightness, camera, reminder, note, notes, setup
    var id: String { rawValue }
}

@MainActor
final class PhoneController: ObservableObject {
    static let shared = PhoneController()

    @Published var sheet: PhoneSheet?
    @Published var message = "Seu iPhone, sob comando."
    @Published var isError = false
    @Published private(set) var isBusy = false
    @Published private(set) var battery: Int?
    @Published private(set) var torchOn = false
    @Published var brightness = Double(UIScreen.main.brightness) * 100
    @Published private(set) var history: [String] = []
    @Published private(set) var notes: [LocalNote] = []

    private let eventStore = EKEventStore()
    private let location = LocationService()
    private let noteStore = NoteStore()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        do { notes = try noteStore.load() }
        catch { report("Não foi possível abrir as notas locais: \(error.localizedDescription)", error: true) }
    }

    func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        battery = level >= 0 ? Int((level * 100).rounded()) : nil
        torchOn = AVCaptureDevice.default(for: .video)?.isTorchActive ?? false
        brightness = Double(UIScreen.main.brightness) * 100
    }

    func report(_ value: String, error: Bool = false) {
        message = value
        isError = error
        history.insert(value, at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
    }

    func run(_ action: PhoneAction) async {
        do { await run(try PhoneCommand(action: action)) }
        catch { report(error.localizedDescription, error: true) }
    }

    func run(_ command: PhoneCommand) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { report(try await perform(command)) }
        catch { report(error.localizedDescription, error: true) }
    }

    func handle(url: URL) async {
        do { await run(try PhoneCommand.decode(url)) }
        catch { report(error.localizedDescription, error: true) }
    }

    func perform(_ command: PhoneCommand) async throws -> String {
        switch command.action {
        case .torchOn, .torchOff:
            let enabled = command.action == .torchOn
            try await setTorch(enabled)
            return enabled ? "Lanterna ligada." : "Lanterna desligada."
        case .brightness:
            if let value = command.percentage {
                UIScreen.main.brightness = CGFloat(value / 100)
                brightness = value
                return "Brilho ajustado para \(Int(value))%."
            }
            brightness = Double(UIScreen.main.brightness) * 100
            sheet = .brightness
            return "Controle de brilho aberto."
        case .volume:
            if command.percentage != nil { return try await openSystemShortcut(command) }
            sheet = .volume
            return "Controle de volume aberto. Ajuste a barra do iPhone."
        case .battery:
            refreshBattery()
            guard let battery else {
                throw PhoneCommandError.unavailable("Bateria indisponível neste dispositivo ou simulador.")
            }
            return "Bateria em \(battery)%."
        case .meeting, .endMeeting, .lowPower, .pause, .play, .next, .lock:
            return try await openSystemShortcut(command)
        case .whatsapp:
            return try await openExternalApp("whatsapp://", name: "WhatsApp")
        case .instagram:
            return try await openExternalApp("instagram://app", name: "Instagram")
        case .camera, .photo:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                throw PhoneCommandError.unavailable("Câmera indisponível. Teste esta ação no iPhone físico.")
            }
            try await authorizeCamera()
            if torchOn { try await setTorch(false) }
            sheet = .camera
            return "Câmera aberta. Ao capturar, a foto será salva em Fotos."
        case .location:
            let coordinate = try await location.currentCoordinate()
            let place = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            place.name = "Minha localização"
            guard place.openInMaps() else {
                throw PhoneCommandError.unavailable("Não foi possível abrir o app Mapas.")
            }
            return "Sua localização foi aberta no Mapas."
        case .reminder:
            sheet = .reminder
            return "Editor de lembrete aberto. Preencha o texto e toque em Salvar."
        case .note:
            sheet = .note
            return "Editor de nota aberto. As notas ficam neste iPhone."
        }
    }

    private func authorizeCamera() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: .video) { return }
        throw PhoneCommandError.permission("Permita acesso à câmera em Ajustes → JARVIS XLV.")
    }

    private func setTorch(_ enabled: Bool) async throws {
        if enabled { try await authorizeCamera() }
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            throw PhoneCommandError.unavailable("Este dispositivo não tem lanterna disponível.")
        }
        guard !enabled || device.isTorchAvailable else {
            throw PhoneCommandError.unavailable("A lanterna está ocupada ou temporariamente indisponível.")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if enabled { try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) }
        else { device.torchMode = .off }
        torchOn = device.isTorchActive
    }

    private func openExternalApp(_ rawURL: String, name: String) async throws -> String {
        guard let url = URL(string: rawURL), UIApplication.shared.canOpenURL(url) else {
            throw PhoneCommandError.unavailable("Instale o \(name) para usar esta ação.")
        }
        guard await UIApplication.shared.open(url) else {
            throw PhoneCommandError.unavailable("O iPhone não conseguiu abrir o \(name).")
        }
        return "Abertura do \(name) solicitada."
    }

    private func openSystemShortcut(_ command: PhoneCommand) async throws -> String {
        guard await UIApplication.shared.open(command.systemShortcutURL) else {
            throw PhoneCommandError.unavailable("Não foi possível abrir o app Atalhos.")
        }
        return "Pedido encaminhado ao Atalhos. Confira o resultado lá. Se necessário, importe JARVIS Sistema."
    }

    func savePhoto(_ image: UIImage) async {
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw PhoneCommandError.permission("Permita adicionar imagens em Fotos nos Ajustes do JARVIS XLV.")
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            report("Foto salva em Fotos.")
        } catch { report(error.localizedDescription, error: true) }
    }

    func saveReminder(title: String, due: Date?) async throws {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PhoneCommandError.unavailable("Escreva o lembrete antes de salvar.") }
        guard try await eventStore.requestFullAccessToReminders() else {
            throw PhoneCommandError.permission("Permita acesso a Lembretes nos Ajustes do JARVIS XLV.")
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw PhoneCommandError.unavailable("Configure uma lista padrão no app Lembretes e tente novamente.")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = value
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try eventStore.save(reminder, commit: true)
        report("Lembrete salvo no app Lembretes.")
    }

    func saveNote(text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PhoneCommandError.unavailable("Escreva a nota antes de salvar.") }
        let updated = [LocalNote(id: UUID(), text: value, date: Date())] + notes
        try noteStore.save(updated)
        notes = updated
        report("Nota salva neste iPhone.")
    }

    func deleteNotes(at offsets: IndexSet) {
        do {
            let updated = notes.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            try noteStore.save(updated)
            notes = updated
        } catch { report(error.localizedDescription, error: true) }
    }
}
