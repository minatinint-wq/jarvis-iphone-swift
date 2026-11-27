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
    case model(String), resizeObject(Float), moveObject(Float,Float), saveMap, room(String), desktop
    case character(String), headset(Bool), recover, keyboard(Bool)
    case roomSetup,roomWall(String),roomClear,effects,calibrate,portal,closePortal
    case roomForest(Bool),doorPortal,registerForest,forestGame(String)

    /// Only navigation-like speech enters the spatial interpreter; ordinary tools stay available.
    static func needsInterpretation(_ input: String) -> Bool {
        let s=PhoneIntentPhrases.normalized(input)
        guard s.range(of:#"\b(nao|nunca|nem|explique|se eu)\b"#,options:.regularExpression)==nil else { return false }
        return s.range(of:#"^(?:abre|abra|abrir|ver|mostra|mostre|mostrar|exibe|exiba|exibir|me leva|me leve|volta|volte|voltar|vai para|va para|entra|entre|seleciona|selecione|selecionar|escolhe|escolha|fecha|feche|fechar|play|retoma|retome|pausa|pause|proxima faixa|faixa anterior|mais playlists|mais faixas|toca essa|toque essa|toca a selecionada|toque a selecionada)\b"#,options:.regularExpression) != nil
    }

    static func parse(_ input: String, inStudio: Bool) -> Self? {
        let s = PhoneIntentPhrases.normalized(input)
        guard !s.isEmpty, s.range(of: #"\b(nao|nunca|nem|talvez|disse|dizer|dissesse|se)\b"#, options: .regularExpression) == nil else { return nil }
        if inStudio,s.contains("portal"),s.range(of:#"^(?:fecha|feche|fechar|apaga|apague|remova|remover)\b"#,options:.regularExpression) != nil { return .closePortal }
        if s.contains("portal"),s.range(of:#"\bportas?\b"#,options:.regularExpression) != nil,!s.contains("parede") { return .doorPortal }
        if s.contains("floresta"),(s.contains("quarto") || s.contains("casa")),s.range(of:#"^(?:transforma|transforme|transformar|cria|crie|criar|ativa|ative|ativar)\b"#,options:.regularExpression) != nil { return .roomForest(true) }
        if ["iniciar jogo da floresta","jogar na floresta","iniciar cacada","cacada da floresta","modo jogo","jogar novamente","iniciar minigame"].contains(s) { return .forestGame("start") }
        if inStudio,["pausar jogo","pausa o jogo"].contains(s) { return .forestGame("pause") }
        if inStudio,["continuar jogo","continua o jogo","retomar jogo"].contains(s) { return .forestGame("resume") }
        if inStudio,["sair do jogo","fechar jogo","parar jogo"].contains(s) { return .forestGame("stop") }
        if inStudio,["mostrar placar","qual minha pontuacao","meu placar"].contains(s) { return .forestGame("score") }
        if ["quarto tomado por floresta","modo floresta","ativar floresta do quarto","floresta no meu quarto","entrar no portal","entra no portal","entrar na floresta","cria uma floresta neste quarto","transformar meu quarto em floresta","transforma meu quarto numa floresta","transforma o quarto em floresta","transforme meu quarto em floresta"].contains(s) { return .roomForest(true) }
        if inStudio,["sair da floresta","sair do portal","voltar para o quarto real","volta pro quarto real","desativar floresta","fechar floresta"].contains(s) { return .roomForest(false) }
        if ["abrir portal","abre o portal","portal na porta","abrir portal na porta","coloca o portal na porta","arma de portal","modo arma de portal","ativar arma de portal","portal com a mao","ativar portal com a mao"].contains(s) { return .doorPortal }
        if inStudio,["calibrar floresta","alinhar floresta","reconhecer meu quarto","reconhecer o quarto","alinhar quarto automaticamente"].contains(s) { return .registerForest }
        if ["abrir portal","abre o portal","abrir portal na parede","abre um portal na parede","cria um portal","criar portal","portal na parede","portal de parede"].contains(s) { return .portal }
        if inStudio,["fechar portal","fecha o portal","remover portal","apagar portal"].contains(s) { return .closePortal }
        if ["modo vr box","vr box","ativar vr box","abrir vr box","modo oculos","ativar modo oculos"].contains(s) { return .headset(true) }
        if inStudio,["sair do vr box","sair vr","desativar vr box","modo celular","sair do modo oculos"].contains(s) { return .headset(false) }
        if inStudio,["recuperar posicao","recupera a posicao","recupere a posicao","recuperar sem apagar","retomar vr","retoma o vr","recuperar visor","recuperar mapa"].contains(s) { return .recover }
        if inStudio,["teclado","abrir teclado","abre o teclado","mostrar teclado","mostrar teclado virtual","digitar no computador","modo digitar"].contains(s) { return .keyboard(true) }
        if inStudio,["fechar teclado","fecha o teclado","recolher teclado","esconder teclado"].contains(s) { return .keyboard(false) }
        if s.range(of: #"^(?:(?:abre|abra|abrir|ativa|ative|ativar) (?:o )?)?(?:modo ar|realidade aumentada|pintura ar|parede ar|pintar parede)$"#, options: .regularExpression) != nil { return .open }
        if let module=SpatialModule.opening(input), inStudio || s.range(of:#"\b(painel|modulo|modulos|central|interface|controles)\b"#,options:.regularExpression) != nil { return .panel(module) }
        let scenes: [String:SpatialTheme] = ["abre o bosque":.forest,"abre a floresta":.forest,"coloca uma floresta":.forest,"cenario floresta":.forest,"cenario bosque":.forest,"bosque noturno":.enchanted,"floresta encantada":.enchanted,"cenario noturno":.enchanted,"cenario estudio":.studio,"abre o estudio ar":.studio,"coloca o radio":.studio,"cenario garagem":.garage,"abrir garagem":.garage,"abre a garagem":.garage,"cenario sala":.lounge,"sala interativa":.lounge,"jardim aquatico":.aquarium,"cenario aquario":.aquarium]
        if let scene=scenes[s] { return .theme(scene) }
        if ["abre o modo espacial","abre o modo cenarios","cenarios ar","modo espacial"].contains(s) { return .theme(.forest) }
        if inStudio {
            if ["calibrar ambiente","calibrar ar","calibrar de novo","recalibrar","calibrar por oito segundos","refazer leitura","repetir leitura"].contains(s) { return .calibrate }
            if ["catalogo de efeitos","abrir efeitos","abre os efeitos","abrir catalogo de efeitos","menu de efeitos"].contains(s) { return .effects }
            if ["alinhar quarto","alinhar captura","alinhar scan","configurar captura do quarto"].contains(s) { return .roomSetup }
            if ["parede de tijolos","testar tijolos","coloca tijolos na parede"].contains(s) { return .roomWall("brick") }
            if ["testar parede branca","teste de parede","testar parede"].contains(s) { return .roomWall("white") }
            if ["abrir tela do computador","abre a tela do computador","puxe a tela do computador","puxa a tela do pc","abrir desktop","abrir area de trabalho","abrir computador"].contains(s) { return .desktop }
            if ["salvar mapa","salva o mapa","salvar ambiente","salva os objetos"].contains(s) { return .saveMap }
            if ["este e o quarto","estou no quarto","ambiente quarto"].contains(s) { return .room("Quarto") }
            if ["esta e a sala","estou na sala","ambiente sala"].contains(s) { return .room("Sala") }
            let actions=["robo acene":"Wave","robo dance":"Dance","robo ande":"walk","robo pare":"stop","testar impacto":"impact","socar parede":"impact","reparar parede":"repair"]
            if let action=actions[s] { return .character(action) }
            let models:[String:String] = ["monstro":"animated_dragon","dragao":"animated_dragon","guardiao":"animated_dragon","personagem":"animated_robot","robo":"animated_robot","raposa":"animated_fox","humanoide":"demo_human","caixa":"demo_box","cadeira":"demo_chair","mesa":"demo_table","abacate":"avocado","garrafa":"waterbottle","lanterna antiga":"lantern","carro":"toycar","peixe":"barramundifish","poltrona":"sheenchair","sofa de veludo":"glamvelvetsofa","tenis":"materialsvariantsshoe","capacete espacial":"scifihelmet","capacete de piloto":"flighthelmet","camera antiga":"antiquecamera","cone":"trafficcone","geladeira":"commercialrefrigerator","relogio":"chronographwatch","cadeira classica":"chairdamaskpurplegold","pufe":"specularsilkpouf","sofa de couro":"sheenwoodleathersofa","luminaria":"anisotropybarnlamp","concha":"iridescenceabalone","vaso de flores":"glassvaseflowers"]
            if s.range(of:#"^(?:coloca|coloque|cria|crie|adiciona|adicione)\b"#,options:.regularExpression) != nil,
               let model=models.keys.sorted(by:{$0.count>$1.count}).first(where:{ s.range(of:"\\b"+NSRegularExpression.escapedPattern(for:$0)+"\\b",options:.regularExpression) != nil }).flatMap({models[$0]}) { return .model(model) }
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
