import Foundation
import UIKit

@MainActor enum PhoneLocalKit {
    static let greeting = "Às suas ordens, magnata."
    private static func normalize(_ input: String) -> String {
        let folded = input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        var text = folded.replacingOccurrences(of: #"[^a-z0-9% ]+"#, with: " ", options: .regularExpression)
        text = text.split(separator: " ").joined(separator: " ")
        text = text.replacingOccurrences(of: #"^(?:(?:oi )?jarvis |por favor )+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #" por favor$"#, with: "", options: .regularExpression)
        return text
    }

    static func studio(for input: String) -> String? {
        let text = normalize(input)
        let sketch = #"^(?:desenhar(?: (?:com o dedo|na tela|no ar))?|(?:abrir?|abra|abre) (?:o )?(?:desenho(?: no ar)?|caderno de desenho|sketchbook)|modo desenho)$"#
        let music = #"^(?:(?:abra|abre|abrir|ative|ativar) (?:os? )?(?:instrumentos|piano|violao|baixo|flauta|bateria)|(?:modo )?instrumentos|tocar (?:piano|violao|baixo|flauta|bateria|instrumentos))$"#
        if text.range(of: sketch, options: .regularExpression) != nil { return "sketch" }
        if text.range(of: music, options: .regularExpression) != nil { return "music" }
        return nil
    }

    // Match the entire request so PC commands mentioning a light, time or battery stay with the assistant.
    static func resolve(_ input: String, readOnly: Bool = false) async -> String? {
        let text = normalize(input)
        let device = #"(?:(?: (?:do|no|da|na|de|em)(?: meu| minha)? (?:iphone|celular|telefone|tela|aparelho))|(?: (?:do|no) dispositivo))?"#
        func matches(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil }

        if matches(#"(?:oi|ola|bom dia|boa tarde|boa noite)(?: jarvis)?|jarvis"#) { return greeting }
        if matches(#"que horas? (?:sao|e)(?: agora)?|(?:qual (?:e )?a |me (?:diga|fala|fale) a |ve(?:ja|r) a )?hora(?: (?:agora|atual|local))?|horario (?:local|atual)"# + device) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "pt_BR")
            formatter.dateFormat = "HH:mm"
            return "Agora são " + formatter.string(from: Date()) + "."
        }
        var action: PhoneAction
        var percentage: Double?
        if matches(#"(?:(?:qual (?:e )?(?:o |a )?|quanto (?:tem |resta |falta )?(?:de )?|como (?:esta|ta) (?:a )?|quant[ao] (?:de )?)?(?:(?:o |a )?(?:percentual|porcentagem|nivel|carga|estado|status) (?:de |da )?)?(?:a |de )?bateria)"# + device + #"(?: (?:resta|tenho|eu tenho|disponivel))?"#) {
            action = .battery
        } else if matches(#"(?:ligar?|ligue|acenda|acende|acender|ative|ativar)(?: a)? lanterna"# + device) {
            action = .torchOn
        } else if matches(#"(?:desligar?|desligue|apague|apaga|apagar|desative|desativar)(?: a)? lanterna"# + device) {
            action = .torchOff
        } else if matches(#"(?:(?:qual (?:e )?(?:o )?)?brilho)"# + device) {
            if readOnly { return "Abra o Jarvis no iPhone desbloqueado para consultar o brilho." }
            return "O brilho da tela está em \(Int((UIScreen.main.brightness * 100).rounded()))%."
        } else if matches(#"(?:(?:ajuste|ajusta|ajustar|defina|definir|coloque|colocar|mude|mudar|ponha) (?:o )?)?brilho"# + device + #"(?: para| em| a)? [0-9]{1,3}(?:%| por cento)?"#),
                  let range = text.range(of: #"[0-9]{1,3}"#, options: .regularExpression) {
            action = .brightness
            percentage = Double(text[range])
        } else { return nil }
        if readOnly && action != .battery { return "Abra o Jarvis no iPhone desbloqueado para executar essa ação." }
        do { return try await PhoneController.shared.perform(PhoneCommand(action: action, percentage: percentage)) }
        catch { return error.localizedDescription }
    }
}
