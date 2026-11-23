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
    case measure, point, opening, approve, theme(SpatialTheme), interact, removeObject, panel(SpatialModule), navigate(String)
    case model(String), resizeObject(Float), moveObject(Float,Float), saveMap, room(String)

    /// Only navigation-like speech enters the spatial interpreter; ordinary tools stay available.
    static func needsInterpretation(_ input: String) -> Bool {
        let s=PhoneIntentPhrases.normalized(input)
        guard s.range(of:#"\b(nao|nunca|nem|explique|se eu)\b"#,options:.regularExpression)==nil else { return false }
        return s.range(of:#"^(?:abre|abra|abrir|ver|mostra|mostre|mostrar|exibe|exiba|exibir|me leva|me leve|volta|volte|voltar|vai para|va para|entra|entre|seleciona|selecione|selecionar|escolhe|escolha|fecha|feche|fechar|play|retoma|retome|pausa|pause|proxima faixa|faixa anterior|mais playlists|mais faixas|toca essa|toque essa|toca a selecionada|toque a selecionada)\b"#,options:.regularExpression) != nil
    }

    static func parse(_ input: String, inStudio: Bool) -> Self? {
        let s = PhoneIntentPhrases.normalized(input)
        guard !s.isEmpty, s.range(of: #"\b(nao|nunca|nem|talvez|disse|dizer|dissesse|se)\b"#, options: .regularExpression) == nil else { return nil }
        if s.range(of: #"^(?:(?:abre|abra|abrir|ativa|ative|ativar) (?:o )?)?(?:modo ar|realidade aumentada|pintura ar|parede ar|pintar parede)$"#, options: .regularExpression) != nil { return .open }
        if let module=SpatialModule.opening(input), inStudio || s.range(of:#"\b(painel|modulo|modulos|central|interface|controles)\b"#,options:.regularExpression) != nil { return .panel(module) }
        let scenes: [String:SpatialTheme] = ["abre o bosque":.forest,"abre a floresta":.forest,"cria uma floresta neste quarto":.forest,"coloca uma floresta":.forest,"cenario floresta":.forest,"cenario bosque":.forest,"bosque noturno":.enchanted,"floresta encantada":.enchanted,"cenario noturno":.enchanted,"cenario estudio":.studio,"abre o estudio ar":.studio,"coloca o radio":.studio,"cenario garagem":.garage,"abrir garagem":.garage,"abre a garagem":.garage,"cenario sala":.lounge,"sala interativa":.lounge,"jardim aquatico":.aquarium,"cenario aquario":.aquarium]
        if let scene=scenes[s] { return .theme(scene) }
        if ["abre o modo espacial","abre o modo cenarios","cenarios ar","modo espacial"].contains(s) { return .theme(.forest) }
        if inStudio {
            if ["salvar mapa","salva o mapa","salvar ambiente","salva os objetos"].contains(s) { return .saveMap }
            if ["este e o quarto","estou no quarto","ambiente quarto"].contains(s) { return .room("Quarto") }
            if ["esta e a sala","estou na sala","ambiente sala"].contains(s) { return .room("Sala") }
            let models:[String:String] = ["personagem":"demo_human","humanoide":"demo_human","caixa":"demo_box","cadeira":"demo_chair","mesa":"demo_table"]
            if s.range(of:#"^(?:coloca|coloque|cria|crie|adiciona|adicione)\b"#,options:.regularExpression) != nil,
               let model=s.split(separator:" ").compactMap({ models[String($0)] }).first { return .model(model) }
            if ["aumente esse objeto","aumenta esse objeto","aumentar objeto"].contains(s) { return .resizeObject(1.15) }
            if ["diminua esse objeto","diminui esse objeto","diminuir objeto"].contains(s) { return .resizeObject(0.85) }
            if ["leve o objeto para a esquerda","mova o objeto para a esquerda"].contains(s) { return .moveObject(-0.1,0) }
            if ["leve o objeto para a direita","mova o objeto para a direita"].contains(s) { return .moveObject(0.1,0) }
            if ["marcar parede","marca a parede","medir parede","marcar cantos"].contains(s) { return .measure }
            if ["adicionar ponto","marca esse ponto","marca aqui","adiciona ponto"].contains(s) { return .point }
            if ["excluir area","excluir porta","excluir armario","marca a porta","marca o armario"].contains(s) { return .opening }
            if ["aplicar recorte","aplica o recorte","confirmar recorte","aplicar pintura"].contains(s) { return .approve }
            if ["interagir","ativar objeto","ativa o objeto"].contains(s) { return .interact }
            if ["remove o objeto","remover objeto"].contains(s) { return .removeObject }
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
