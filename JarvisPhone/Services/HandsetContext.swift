import Foundation
import UIKit
import Combine
import CoreMotion
import EventKit
import Contacts
import MessageUI
import UserNotifications

struct PhonePreview: Codable, Equatable {
    let text: String
    let date: Date
}

@MainActor final class HandsetContext: NSObject, ObservableObject, MFMessageComposeViewControllerDelegate {
    static let shared = HandsetContext()
    @Published private(set) var steps: Int?
    @Published private(set) var stepsDate: Date?
    @Published private(set) var preview: PhonePreview?
    @Published private(set) var battery: Int?
    @Published private(set) var upcoming: String?
    @Published var notice = ""
    var onChange: (() -> Void)?
    var onSMSResult: ((String) -> Void)?
    private let meter = CMPedometer()
    private let calendars = EKEventStore()
    private let contacts = CNContactStore()
    private var stepQuery: Task<Int?, Never>?
    private var lastBattery: Int?
    private var batteryLow = false
    private var announcedEvent: String?
    private var milestoneDay: Date?
    private var pending: (target: String, number: String, body: String?, until: Date)?
    private static var previewFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarvisLatestPreview.json")
    }
    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let data = try? Data(contentsOf: Self.previewFile) {
            preview = try? JSONDecoder().decode(PhonePreview.self, from: data)
        }
        refreshBattery()
    }
    func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        let percent = level >= 0 ? Int((level * 100).rounded()) : nil
        if battery != percent { battery = percent; onChange?() }
    }
    func remember(_ text: String, date: Date = Date()) -> Bool {
        let clean = String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(700))
        guard !clean.isEmpty, !clean.contains("JARVIS_COMANDO") else { return false }
        if let old = preview, old.date > date || (old.text == clean && date.timeIntervalSince(old.date) < 12) { return false }
        let entry = PhonePreview(text: clean, date: date)
        do {
            try FileManager.default.createDirectory(at: Self.previewFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: Self.previewFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { notice = "Prévia disponível nesta sessão. O iPhone não permitiu salvá-la." }
        preview = entry
        onChange?()
        return true
    }
    func clearPreview() {
        UserDefaults.standard.set(Date(), forKey: "jarvis.previewCleared")
        preview = nil
        try? FileManager.default.removeItem(at: Self.previewFile)
        onChange?()
    }
    func refreshDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let cleared = UserDefaults.standard.object(forKey: "jarvis.previewCleared") as? Date ?? .distantPast
        if let n = delivered.filter({ $0.date > cleared }).max(by: { $0.date < $1.date }), n.date > (preview?.date ?? .distantPast) {
            let c = n.request.content
            _ = remember([c.title,c.body].filter { !$0.isEmpty }.joined(separator: ". "), date: n.date)
        }
    }
    func readSteps(requestPermission: Bool) async -> Int? {
        let now = Date()
        if let date = stepsDate, !Calendar.current.isDate(date, inSameDayAs: now) { steps = nil; stepsDate = nil; onChange?() }
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        let status = CMPedometer.authorizationStatus()
        guard status == .authorized || (status == .notDetermined && requestPermission && UIApplication.shared.applicationState == .active) else {
            if steps != nil { steps = nil; stepsDate = nil; onChange?() }
            return nil
        }
        if let task = stepQuery { return await task.value }
        let start = Calendar.current.startOfDay(for: now)
        let task = Task<Int?, Never> {
            await withCheckedContinuation { cont in
                meter.queryPedometerData(from: start, to: now) { data, error in
                    cont.resume(returning: error == nil ? data?.numberOfSteps.intValue : nil)
                }
            }
        }
        stepQuery = task
        let count = await task.value
        stepQuery = nil
        if let count { steps = count; stepsDate = now; onChange?() }
        return count
    }
    func stepsReply(requestPermission: Bool) async -> String {
        if let n = await readSteps(requestPermission: requestPermission) { return "O iPhone registrou \(n) passos hoje." }
        if !CMPedometer.isStepCountingAvailable() { return "Este aparelho não disponibiliza a contagem de passos." }
        if CMPedometer.authorizationStatus() != .authorized { return "Para contar os passos, autorize Movimento e Preparo Físico para o Jarvis nos Ajustes do iPhone." }
        return "O iPhone não devolveu a contagem de passos agora."
    }
    func enableCalendar() async {
        do {
            guard try await calendars.requestFullAccessToEvents() else { notice = "Autorize Calendários nos Ajustes para receber avisos."; return }
            notice = "Agenda do iPhone conectada."
            _ = upcomingEvent()
        } catch { notice = "Não consegui acessar a agenda do iPhone." }
    }
    private func upcomingEvent() -> EKEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { upcoming = nil; return nil }
        let now = Date()
        let query = calendars.predicateForEvents(withStart: now, end: now.addingTimeInterval(86400), calendars: nil)
        let event = calendars.events(matching: query).filter { !$0.isAllDay && $0.status != .canceled && $0.startDate >= now }.min { $0.startDate < $1.startDate }
        let label = event.map { ($0.title ?? "Compromisso") + " · " + $0.startDate.formatted(date: .omitted, time: .shortened) }
        if upcoming != label { upcoming = label; onChange?() }
        return event
    }
    func proactiveNotice() async -> String? {
        refreshBattery()
        defer { lastBattery = battery }
        if let b = battery {
            let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            if b > 25 || charging { batteryLow = false }
            if b <= 20 && !charging && !batteryLow { batteryLow = true; return "A bateria do iPhone está em \(b)%." }
            if let old = lastBattery, old < 100, b == 100, charging { return "O iPhone terminou de carregar." }
        }
        if let event = upcomingEvent(), event.startDate.timeIntervalSinceNow <= 600 {
            let key = (event.eventIdentifier ?? event.title ?? "") + String(event.startDate.timeIntervalSince1970)
            if key != announcedEvent { announcedEvent = key; return "Seu compromisso \(event.title ?? "") começa às \(event.startDate.formatted(date: .omitted, time: .shortened))." }
        }
        if let count = await readSteps(requestPermission: false), count >= 5000 {
            let day = Calendar.current.startOfDay(for: Date())
            if milestoneDay != day { milestoneDay = day; return "Você já passou de cinco mil passos hoje. O iPhone registrou \(count)." }
        }
        return nil
    }
    enum Request: Equatable {
        case steps, notification, call(String), sms(String, String)
    }
    static func parse(_ input: String) -> Request? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:(?:ei|oi|hey)[, ]+)?jarvis[, !:.?]+"#, with: "", options: [.regularExpression,.caseInsensitive])
        let words = PhoneVoiceControl.words(raw)
        if words.range(of: #"^(?:(?:quantos|quantidade de|meus) passos(?: (?:eu )?(?:dei|andei|fiz|tenho|caminhei))?(?: (?:de )?(?:hoje|hj))?|passos (?:de )?(?:hoje|hj))$"#, options:.regularExpression) != nil { return .steps }
        if words.range(of: #"^(?:(?:qual(?: foi| e)?|leia|ler|mostre|repita) )?(?:a )?(?:minha )?ultima notificacao(?: (?:que chegou|do iphone|do celular))?$"#, options:.regularExpression) != nil { return .notification }
        func groups(_ pattern: String) -> [String]? {
            guard let r = try? NSRegularExpression(pattern: pattern, options:.caseInsensitive),
                  let m = r.firstMatch(in:raw, range:NSRange(raw.startIndex..., in:raw)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at:$0), in:raw).map { String(raw[$0]).trimmingCharacters(in:.whitespacesAndNewlines) } }
        }
        if let p = groups(#"^(?:manda|mande|mandar|envia|envie|enviar|escreva|escreve) (?:um |uma )?(?:sms|mensagem de texto) (?:para|pra|pro) (.{1,100}?)(?:\s*:\s*|[, ]+(?:dizendo|falando|com o texto)\s+)(.{1,1200})$"#), p.count == 2 { return .sms(p[0],p[1]) }
        if words.contains("whatsapp") || words.contains("zap") { return nil }
        if let p = groups(#"^(?:(?:faça|faca) uma ligação|ligue|liga|ligar|telefone|telefonar) (?:para|pra|pro) (.{1,100}?)\s*[.!?]?$"#) { return .call(p[0]) }
        return nil
    }
    func cancelPending() { pending = nil }
    private func resolveNumber(_ target: String) async throws -> String {
        let trimmed = target.trimmingCharacters(in:.whitespacesAndNewlines)
        func number(_ text: String) -> String? {
            guard text.range(of: #"^\+?[0-9 ()-]+$"#,options:.regularExpression) != nil else { return nil }
            let digits = text.filter { $0.isNumber }
            guard (3...15).contains(digits.count) else { return nil }
            return (text.hasPrefix("+") ? "+" : "") + digits
        }
        if let direct = number(trimmed) { return direct }
        guard try await contacts.requestAccess(for:.contacts) else { throw HandsetIssue("Permita Contatos nos Ajustes ou diga o número com DDD.") }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for:.fullName),CNContactPhoneNumbersKey as CNKeyDescriptor,CNContactNicknameKey as CNKeyDescriptor]
        let found = try contacts.unifiedContacts(matching:CNContact.predicateForContacts(matchingName: trimmed), keysToFetch:keys)
        let expected = PhoneVoiceControl.words(trimmed)
        let matches = found.filter { c in [CNContactFormatter.string(from:c,style:.fullName) ?? "", c.givenName, c.nickname].contains { PhoneVoiceControl.words($0) == expected } }
        guard matches.count == 1 else { throw HandsetIssue(matches.isEmpty ? "Não encontrei esse contato. Diga o nome salvo ou o número com DDD." : "Há mais de um contato com esse nome. Diga nome e sobrenome ou o número com DDD.") }
        let numbers = Set(matches[0].phoneNumbers.compactMap { number($0.value.stringValue) })
        guard numbers.count == 1, let n = numbers.first else { throw HandsetIssue("Esse contato não tem um único número. Diga o número com DDD.") }
        return n
    }
    func respond(_ text: String, locked: Bool) async -> String? {
        let words = PhoneVoiceControl.words(text).replacingOccurrences(of:#"^(?:(?:ei|oi) )?jarvis "#,with:"",options:.regularExpression)
        if let item = pending {
            pending = nil
            if item.until > Date(), ["não","nao","cancela","cancelar"].contains(words) { return "Pedido cancelado." }
            if item.until > Date(), ["sim","ok","pode seguir","confirmo","pode ligar","pode enviar"].contains(words) {
                guard !locked, UIApplication.shared.applicationState == .active else { return "Desbloqueie o iPhone e faça o pedido de novo." }
                if let body = item.body { return showComposer(to:item.number, body:body) }
                guard let url = URL(string:"tel:" + item.number), await UIApplication.shared.open(url) else { return "O iPhone não conseguiu abrir a ligação." }
                return "Ligação encaminhada ao Telefone."
            }
        }
        let localWords = PhoneVoiceControl.words(text).replacingOccurrences(of: #"^(?:(?:oi|ei) )?jarvis "#, with: "", options: .regularExpression)
        if ["resumo do iphone", "meu resumo", "resumo do dia", "status do iphone", "me de um resumo"].contains(localWords) {
            return await localBriefing(includeAgenda: !locked)
        }
        if let range = text.range(of: #"^(?:(?:(?:Oi|Ei)[, ]+)?Jarvis[, ]+)?(?:anote|anota|anotar|guarde uma nota)[: ,]+"#, options: [.regularExpression, .caseInsensitive]) {
            guard !locked, UIApplication.shared.applicationState == .active else { return "Desbloqueie o iPhone para guardar uma nota." }
            let body = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.count <= 2000 else { return "Diga o conteúdo da nota, em até dois mil caracteres." }
            do { try PhoneController.shared.saveNote(text: body); return "Nota salva neste iPhone." }
            catch { return "Não consegui salvar a nota no iPhone." }
        }
        guard let request = Self.parse(text) else { return nil }
        switch request {
        case .steps: return await stepsReply(requestPermission: !locked)
        case .notification:
            await refreshDelivered()
            guard let preview else { return "Ainda não recebi uma prévia. Em Atalhos, configure uma automação que passe o texto para Anunciar notificação no Jarvis." }
            return "Às \(preview.date.formatted(date: .omitted, time: .shortened)), \(preview.text)"
        case .call, .sms:
            guard !locked, UIApplication.shared.applicationState == .active else { return "Abra o Jarvis no iPhone desbloqueado para ligar ou preparar o SMS." }
            let target: String, body: String?
            switch request { case .call(let t): target=t; body=nil
            case .sms(let t, let b): target=t; body=b
            default: return nil }
            do {
                let n = try await resolveNumber(target)
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return "Pedido interrompido." }
                pending = (target,n,body,Date().addingTimeInterval(60))
                let who = "\(target), final \(n.suffix(4))"
                return body.map { "SMS para \(who). Texto: \($0). Posso abrir a mensagem?" } ?? "Posso ligar para \(who)?"
            } catch { return (error as? HandsetIssue)?.message ?? "Não consegui consultar os contatos do iPhone." }
        }
    }
    func localBriefing(includeAgenda: Bool) async -> String {
        refreshBattery()
        var lines = ["Agora são " + Date().formatted(date: .omitted, time: .shortened) + "."]
        if let battery { lines.append("Bateria em \(battery)%.") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { lines.append("Modo Pouca Energia ativo.") }
        if let count = await readSteps(requestPermission: false) { lines.append("\(count) passos hoje.") }
        if includeAgenda, UIApplication.shared.isProtectedDataAvailable {
            _ = upcomingEvent()
            if let upcoming { lines.append("Próximo compromisso: " + upcoming + ".") }
        }
        return lines.joined(separator: " ")
    }
    private func showComposer(to number: String, body: String) -> String {
        guard MFMessageComposeViewController.canSendText() else { return "O Mensagens deste iPhone não está disponível para envio." }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var parent = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let child = parent?.presentedViewController { parent = child }
        guard let parent, !(parent is MFMessageComposeViewController), parent.viewIfLoaded?.window != nil else { return "Feche a janela atual e repita o pedido de SMS." }
        let composer = MFMessageComposeViewController()
        composer.recipients = [number]; composer.body = body; composer.messageComposeDelegate = self
        parent.present(composer, animated:true)
        return "Mensagem pronta. Confira e toque em Enviar."
    }
    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated:true)
        let text = result == .sent ? "O Mensagens aceitou o envio." : result == .cancelled ? "Envio cancelado." : "O Mensagens informou uma falha no envio."
        notice = text; onSMSResult?(text)
    }
}
private struct HandsetIssue: Error { let message: String; init(_ message: String) { self.message = message } }
