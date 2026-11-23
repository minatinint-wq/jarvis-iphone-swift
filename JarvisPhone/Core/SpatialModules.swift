import Foundation

enum SpatialModule: String, CaseIterable {
    case dashboard, spotify, phone, home, camera, creation, scenes, instruments, libras, translation, personal
    var title: String {
        switch self {
        case .dashboard: return "Central JARVIS"
        case .spotify: return "Spotify"
        case .phone: return "Controles do iPhone"
        case .home: return "Casa · Tuya"
        case .camera: return "Visão e câmera"
        case .creation: return "Criação"
        case .scenes: return "Cenários AR"
        case .instruments: return "Instrumentos"
        case .libras: return "Libras"
        case .translation: return "Tradução"
        case .personal: return "Meu dia"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard:return "square.grid.2x2"
        case .spotify:return "music.note.list"
        case .phone:return "slider.horizontal.3"
        case .home:return "house"
        case .camera:return "camera.viewfinder"
        case .creation:return "paintbrush.pointed"
        case .scenes:return "cube.transparent"
        case .instruments:return "guitars"
        case .libras:return "hands.sparkles"
        case .translation:return "character.bubble"
        case .personal:return "sun.max"
        }
    }
    static func opening(_ text: String) -> SpatialModule? {
        let s=PhoneIntentPhrases.normalized(text)
        guard s.range(of:#"\b(nao|nunca|nem|se|disse|explique)\b"#,options:.regularExpression)==nil else { return nil }
        guard let range=s.range(of:#"^(?:abre|abra|abrir|mostra|mostre|mostrar|exibe|exiba|exibir|acessa|acesse|acessar|entra|entre|entrar)(?: (?:o|a|os|as|no|na|nos|nas|meu|minha|minhas|meus))* "#,options:.regularExpression) else { return nil }
        var subject=String(s[range.upperBound...])
        subject=subject.replacingOccurrences(of:#"^(?:modulo|painel|interface|controles?)(?: de| do| da)? "#,with:"",options:.regularExpression)
        subject=subject.replacingOccurrences(of:#" (?:em ar|em realidade aumentada|em realidade virtual|do jarvis|espacial)$"#,with:"",options:.regularExpression)
        let aliases: [SpatialModule:[String]] = [
            .dashboard:["painel","central","menu","interface","modulos","funcoes","painel principal"],
            .spotify:["spotify","musica","musicas","playlists"],
            .phone:["controles","controle","iphone","celular","telefone","controles do iphone"],
            .home:["casa","tuya","casa inteligente","luzes","lampadas","dispositivos"],
            .camera:["camera","visao","visao artificial"],.creation:["criacao","desenho","imagens"],
            .scenes:["cenarios","cenario","ambientes","objetos 3d"],.instruments:["instrumentos","harpa","guitarra","violao"],
            .libras:["libras"],.translation:["traducao","tradutor"],.personal:["dia","meu dia","agenda","email","e mail","resumo"]]
        return aliases.first(where:{$0.value.contains(subject)})?.key
    }
}

enum SpatialPanelAction {
    case module(SpatialModule), command(String), studio(String), scene(SpatialTheme), spotify(String,String?), page(Int), refresh, reposition, close
}
