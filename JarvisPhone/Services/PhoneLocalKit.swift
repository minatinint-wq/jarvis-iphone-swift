import Foundation
import UIKit
import AVFoundation

@MainActor enum PhoneLocalKit {
    static let greeting = "Às suas ordens, magnata."
    private static func normalize(_ input: String) -> String { PhoneIntentPhrases.normalized(input) }

    static func studio(for input: String) -> String? {
        let text = normalize(input)
        let sketch = #"^(?:desenhar(?: (?:com o dedo|na tela|no ar))?|(?:abrir?|abra|abre) (?:o )?(?:desenho(?: no ar)?|caderno de desenho|sketchbook)|modo desenho)$"#
        let music = #"^(?:(?:abra|abre|abrir|ative|ativar) (?:os? )?(?:instrumentos|piano|violao|baixo|flauta|bateria)|(?:modo )?instrumentos|tocar (?:piano|violao|baixo|flauta|bateria|instrumentos))$"#
        if text.range(of: sketch, options: .regularExpression) != nil { return "sketch" }
        if text.range(of: music, options: .regularExpression) != nil { return "music" }
        return nil
    }

    static func torchAction(_ input: String) -> PhoneAction? { PhoneIntentPhrases.torch(input) }

    // Match the entire request so PC commands mentioning a light, time or battery stay with the assistant.
    static func resolve(_ input: String, readOnly: Bool = false) async -> String? {
        var text = normalize(input)
        if text.contains("brilho") || text.contains("volume") {
            text = text.replacingOccurrences(of: #"^(?:voce )?(?:pode |consegue )"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: " pra ", with: " para ")
            text = text.replacingOccurrences(of: #"(?<=\d)\s+%"#, with: "%", options: .regularExpression)
            let formatter = NumberFormatter()
            formatter.numberStyle = .spellOut
            formatter.locale = Locale(identifier: "pt_BR")
            if let suffix = text.range(of: #"(?<= )(?:[a-z]+(?: e [a-z]+)?)(?: por cento)?$"#, options: .regularExpression) {
                let words = String(text[suffix]).replacingOccurrences(of: " por cento", with: "")
                if let number = formatter.number(from: words), let canonical = formatter.string(from: number),
                   normalize(canonical) == words { text.replaceSubrange(suffix, with: number.stringValue + "%") }
            }
        }
        text = text.replacingOccurrences(of: #" (?:de novo|novamente|por favor)$"#, with: "", options: .regularExpression)
        let device = #"(?:(?: (?:do|no|da|na|de|em)(?: meu| minha)? (?:iphone|celular|telefone|tela|aparelho))|(?: (?:do|no) dispositivo))?"#
        func matches(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil }

        if matches(#"(?:oi|ola|bom dia|boa tarde|boa noite)(?: jarvis)?|jarvis"#) { return greeting }
        if let reply = await PhoneAlmanac.reply(text, locked: readOnly) { return reply }
        if let localAction = PhoneSystemVoice.action(input) {
            if readOnly { return "Desbloqueie e abra o Jarvis para encaminhar esta ação ao Atalhos." }
            do { return try await PhoneController.shared.perform(PhoneCommand(action: localAction)) }
            catch { return error.localizedDescription }
        }
        var action: PhoneAction
        var percentage: Double?
        if matches(#"(?:(?:qual (?:e )?(?:o |a )?|quanto (?:tem |resta |falta )?(?:de )?|como (?:esta|ta) (?:a )?|quant[ao] (?:de )?)?(?:(?:o |a )?(?:percentual|porcentagem|nivel|carga|estado|status) (?:de |da )?)?(?:a |de )?bateria)"# + device + #"(?: (?:resta|tenho|eu tenho|disponivel))?"#) {
            action = .battery
        } else if let torch = torchAction(input) {
            action = torch
        } else if text.range(of:#"\b(?:lanterna|flash)\b"#, options:.regularExpression) != nil && text.range(of:#"\b(?:lig\w*|deslig\w*|acend\w*|apag\w*|ativ\w*|desativ\w*)\b"#,options:.regularExpression) != nil {
            return "Para controlar a lanterna deste iPhone, diga “ligue a lanterna” ou “apague a lanterna”."
        } else if matches(#"(?:aumenta|aumente|sobe|suba|diminui|diminua|abaixa|abaixe|reduz|reduza|baixe) (?:o )?(?:volume|som)"# + device) {
            let lower = ["dimin", "abaix", "redu", "baix"].contains(where: { text.hasPrefix($0) })
            action = .volume
            percentage = min(100, max(0, (Double(AVAudioSession.sharedInstance().outputVolume) * 100).rounded() + (lower ? -10 : 10)))
        } else if matches(#"(?:clareia|clareie|escurece|escureca) (?:a )?tela"# + device) {
            action = .brightness
            percentage = min(100, max(0, (Double(UIScreen.main.brightness) * 100).rounded() + (text.hasPrefix("escur") ? -10 : 10)))
        } else if matches(#"(?:(?:qual (?:e )?(?:o )?)?brilho)"# + device) {
            if readOnly { return "Abra o Jarvis no iPhone desbloqueado para consultar o brilho." }
            return "O brilho da tela está em \(Int((UIScreen.main.brightness * 100).rounded()))%."
        } else if matches(#"(?:aumenta|aumente|sobe|suba|diminui|diminua|abaixa|abaixe|reduz|reduza|baixe) (?:o )?brilho"# + device) {
            let lower = ["dimin", "abaix", "redu", "baix"].contains(where: { text.hasPrefix($0) })
            action = .brightness
            percentage = min(100, max(0, (Double(UIScreen.main.brightness) * 100).rounded() + (lower ? -10 : 10)))
        } else if matches(#"(?:(?:ajuste|ajusta|ajustar|altera|altere|alterar|bota|coloque|defina|definir|coloque|coloca|colocar|mude|muda|mudar|ponha|aumente|aumenta|diminua|abaixa) (?:o )?)?brilho"# + device + #"(?: para| em| a)? [0-9]{1,3}(?:%| por cento)?"#),
                  let range = text.range(of: #"[0-9]{1,3}"#, options: .regularExpression) {
            action = .brightness
            percentage = Double(text[range])
        } else if matches(#"(?:(?:ajuste|ajusta|defina|coloca|coloque|mude|aumente|abaixe) (?:o )?)?volume"# + device + #"(?: para| em| a)? [0-9]{1,3}(?:%| por cento)?"#),
                  let range = text.range(of: #"[0-9]{1,3}"#, options: .regularExpression) {
            action = .volume
            percentage = Double(text[range])
        } else { return nil }
        if readOnly && action != .battery && action != .torchOn && action != .torchOff { return "Abra o Jarvis no iPhone desbloqueado para executar essa ação." }
        do { return try await PhoneController.shared.perform(PhoneCommand(action: action, percentage: percentage)) }
        catch { return error.localizedDescription }
    }
}
