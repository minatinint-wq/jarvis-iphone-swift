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

    static func torchAction(_ input: String) -> PhoneAction? {
        var s = normalize(input)
        s = s.replacingOccurrences(of: #"^(?:(?:voce |vc )?(?:pode|consegue|poderia) |(?:eu )?(?:queria|quero) (?:que (?:voce )?)?|por gentileza |por favor )+"#, with:"", options:.regularExpression)
        s = s.replacingOccurrences(of: #"(?:(?: (?:por favor|agora|ai|aqui|pra mim|para mim|por gentileza)))+$"#, with:"", options:.regularExpression)
        let target = #" (?:a |o |minha |meu |essa |esse )?(?:lanterna|flash|luz (?:do|no) (?:meu )?(?:celular|telefone|iphone))(?: (?:do|no|desse|neste|deste) (?:meu |seu )?(?:iphone|celular|telefone|aparelho|dispositivo))?"#
        for (pattern, a): (String,PhoneAction) in [(#"(?:lig[ae]|ligar|ligue|acend[ae]|acender|ativ[ae]|ativar|ative)"#, .torchOn), (#"(?:deslig[ae]|desligar|desligue|apag[ae]|apague|apagar|desativ[ae]|desativar|desative)"#, .torchOff)] {
            if s.range(of:"^"+pattern+target+"$",options:.regularExpression) != nil { return a }
        }
        return nil
    }

    // Match the entire request so PC commands mentioning a light, time or battery stay with the assistant.
    static func resolve(_ input: String, readOnly: Bool = false) async -> String? {
        let text = normalize(input)
        let device = #"(?:(?: (?:do|no|da|na|de|em)(?: meu| minha)? (?:iphone|celular|telefone|tela|aparelho))|(?: (?:do|no) dispositivo))?"#
        func matches(_ pattern: String) -> Bool { text.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil }

        if matches(#"(?:oi|ola|bom dia|boa tarde|boa noite)(?: jarvis)?|jarvis"#) { return greeting }
        if let reply = await PhoneAlmanac.reply(text, locked: readOnly) { return reply }
        var action: PhoneAction
        var percentage: Double?
        if matches(#"(?:(?:qual (?:e )?(?:o |a )?|quanto (?:tem |resta |falta )?(?:de )?|como (?:esta|ta) (?:a )?|quant[ao] (?:de )?)?(?:(?:o |a )?(?:percentual|porcentagem|nivel|carga|estado|status) (?:de |da )?)?(?:a |de )?bateria)"# + device + #"(?: (?:resta|tenho|eu tenho|disponivel))?"#) {
            action = .battery
        } else if let torch = torchAction(input) {
            action = torch
        } else if text.range(of:#"\b(?:lanterna|flash)\b"#, options:.regularExpression) != nil && text.range(of:#"\b(?:lig\w*|deslig\w*|acend\w*|apag\w*|ativ\w*|desativ\w*)\b"#,options:.regularExpression) != nil {
            return "Para controlar a lanterna deste iPhone, diga “ligue a lanterna” ou “apague a lanterna”."
        } else if matches(#"(?:(?:qual (?:e )?(?:o )?)?brilho)"# + device) {
            if readOnly { return "Abra o Jarvis no iPhone desbloqueado para consultar o brilho." }
            return "O brilho da tela está em \(Int((UIScreen.main.brightness * 100).rounded()))%."
        } else if matches(#"(?:(?:ajuste|ajusta|ajustar|defina|definir|coloque|colocar|mude|mudar|ponha) (?:o )?)?brilho"# + device + #"(?: para| em| a)? [0-9]{1,3}(?:%| por cento)?"#),
                  let range = text.range(of: #"[0-9]{1,3}"#, options: .regularExpression) {
            action = .brightness
            percentage = Double(text[range])
        } else { return nil }
        if readOnly && action != .battery && action != .torchOn && action != .torchOff { return "Abra o Jarvis no iPhone desbloqueado para executar essa ação." }
        do { return try await PhoneController.shared.perform(PhoneCommand(action: action, percentage: percentage)) }
        catch { return error.localizedDescription }
    }
}
