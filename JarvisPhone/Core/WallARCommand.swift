import Foundation

enum WallFinish: String, CaseIterable, Identifiable {
    case white, ivory, gray, sand, blue, green, red, black, wood, concrete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return "Branco fosco"
        case .ivory: return "Marfim"
        case .gray: return "Cinza"
        case .sand: return "Areia"
        case .blue: return "Azul"
        case .green: return "Verde"
        case .red: return "Vermelho"
        case .black: return "Grafite"
        case .wood: return "Madeira"
        case .concrete: return "Cimento"
        }
    }
    var rgb: (Double, Double, Double) {
        switch self {
        case .white: return (0.94, 0.94, 0.92)
        case .ivory: return (0.89, 0.85, 0.74)
        case .gray: return (0.52, 0.54, 0.55)
        case .sand: return (0.73, 0.62, 0.46)
        case .blue: return (0.24, 0.42, 0.62)
        case .green: return (0.34, 0.49, 0.37)
        case .red: return (0.61, 0.19, 0.14)
        case .black: return (0.12, 0.13, 0.14)
        case .wood, .concrete: return (1, 1, 1)
        }
    }
    var texture: String { self == .wood ? "wood" : self == .concrete ? "concrete" : "plaster" }
    var tileMeters: Float { self == .wood ? 1.5 : 0.8 }
}

enum WallARCommand: Equatable {
    case open, select, finish(WallFinish), undo, clear, compare, close

    static func parse(_ input: String, inStudio: Bool) -> Self? {
        let s = PhoneIntentPhrases.normalized(input)
        guard !s.isEmpty, s.range(of: #"\b(nao|nunca|nem|talvez|disse|dizer|dissesse|se)\b"#, options: .regularExpression) == nil else { return nil }
        if s.range(of: #"^(?:(?:abre|abra|abrir|ativa|ative|ativar) (?:o )?)?(?:modo ar|realidade aumentada|pintura ar|parede ar|pintar parede)$"#, options: .regularExpression) != nil { return .open }
        if inStudio {
            if ["essa parede", "esta parede", "seleciona essa parede", "selecione essa parede", "selecionar parede", "fixa aqui", "pinta aqui"].contains(s) { return .select }
            if ["desfaz", "desfaca", "desfazer", "volta a cor anterior"].contains(s) { return .undo }
            if ["limpa a pintura", "limpar pintura", "remove a pintura", "remova a pintura", "tira a pintura"].contains(s) { return .clear }
            if ["comparar", "mostra o original", "mostrar original", "mostra a pintura", "mostrar pintura"].contains(s) { return .compare }
            if ["fecha o ar", "fechar ar", "fecha o modo ar", "sair do ar", "sair do modo ar", "fechar realidade aumentada"].contains(s) { return .close }
        }
        guard inStudio || s.contains("parede") else { return nil }
        guard s.range(of: #"^(?:pinta|pinte|pintar|deixa|deixe|deixar|troca|troque|trocar|muda|mude|mudar|coloca|coloque|colocar|aplica|aplique|aplicar|transforma|transforme|agora)\b"#, options: .regularExpression) != nil else { return nil }
        // Do not silently apply only part of a request: spatial masks and custom textures
        // need separate tools. Nor should a room-light command repaint the wall.
        guard s.range(of: #"\b(luz|lampada|metade|teto|chao|porta|janela|listras|imagem|foto|desenho|agua)\b"#, options: .regularExpression) == nil else { return nil }
        let choices: [String: WallFinish] = ["branco":.white,"branca":.white,"marfim":.ivory,"bege":.ivory,"cinza":.gray,"areia":.sand,"azul":.blue,"verde":.green,"vermelho":.red,"vermelha":.red,"preto":.black,"preta":.black,"grafite":.black,"madeira":.wood,"carvalho":.wood,"cimento":.concrete,"concreto":.concrete]
        // In "troca a parede cinza para branca", the last material is the destination.
        guard let finish = s.split(separator: " ").reversed().compactMap({ choices[String($0)] }).first else { return nil }
        return .finish(finish)
    }
}

/// Tracking must be continuously good before showing content again. Never draw a
/// screen-fixed replacement while ARKit is relocalizing.
struct WallTrackingGate {
    private var normalSince: TimeInterval?
    mutating func update(normal: Bool, at time: TimeInterval) -> Bool {
        guard normal, time.isFinite else { normalSince = nil; return false }
        if normalSince == nil { normalSince = time }
        return time - (normalSince ?? time) >= 0.6
    }
}
