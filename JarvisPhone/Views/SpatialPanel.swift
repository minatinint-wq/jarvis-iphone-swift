import SwiftUI
import ARKit
import SceneKit

/// An anchored spatial dashboard. Tap targets are separate real SceneKit nodes;
/// the content is drawn crisply into textures, not a screenshot floating in UI.
@MainActor final class SpatialPanel: ObservableObject {
    @Published var visible=false
    @Published var module=SpatialModule.dashboard
    @Published var status="Escolha um módulo."
    private let view: ARSCNView
    private var anchor: ARAnchor?
    private var root: SCNNode?
    private var actions: [String:SpatialPanelAction]=[:]
    private var playlists: [(id:String,name:String)]=[]
    private var offset=0
    private var hasNext=false
    private var pending: String?
    private var timeout: Task<Void,Never>?
    private var lastTap: TimeInterval=0
    var onAction: ((SpatialPanelAction)->Void)?
    var onSpotify: (([String:Any])->Void)?
    init(view: ARSCNView) { self.view=view }

    func open(_ destination: SpatialModule, tracking: Bool) {
        guard tracking else { status="Aguarde o mapeamento estabilizar e abra o painel novamente.";return }
        module=destination
        if root == nil { reposition() }
        guard root != nil else { return }
        visible=true;root?.isHidden=false;status="\(destination.title) · escolha uma ação."
        render()
        if destination == .spotify { request("library") }
    }
    func reposition() {
        guard let frame=view.session.currentFrame else { return }
        var transform=frame.camera.transform
        var distance:Float=1.0
        if let query=view.raycastQuery(from:CGPoint(x:view.bounds.midX,y:view.bounds.midY),allowing:.existingPlaneGeometry,alignment:.any),
           let hit=view.session.raycast(query).first {
            let gap=simd_distance(SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z),SIMD3(transform.columns.3.x,transform.columns.3.y,transform.columns.3.z))-0.18
            guard gap>=0.35 else { status="Afaste o iPhone da superfície para abrir espaço para o painel.";return }
            distance=min(distance,gap)
        }
        if let anchor { view.session.remove(anchor:anchor) };root?.removeFromParentNode()
        transform.columns.3 -= transform.columns.2*distance;transform.columns.3.w=1
        let anchor=ARAnchor(name:"JarvisControlPanel",transform:transform)
        let root=SCNNode();root.simdTransform=transform
        // Maintain legibility and fit view even when a real wall is close.
        let scale=max(0.35,distance);root.simdScale=SIMD3<Float>(repeating:scale)
        self.anchor=anchor;self.root=root;view.scene.rootNode.addChildNode(root);view.session.add(anchor:anchor)
        render()
    }
    func update(_ updated: ARAnchor) {
        if updated.identifier==anchor?.identifier {
            let scale=root?.simdScale ?? SIMD3<Float>(repeating:1)
            anchor=updated;root?.simdTransform=updated.transform;root?.simdScale=scale
        }
    }
    func setTracking(_ good: Bool) { root?.isHidden = !good || !visible }
    func close() {
        timeout?.cancel();pending=nil;visible=false
        if let anchor { view.session.remove(anchor:anchor) };anchor=nil
        root?.removeFromParentNode();root=nil;actions.removeAll()
    }
    func hit(_ point: CGPoint) -> Bool {
        guard visible,root?.isHidden==false else { return false }
        for result in view.hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue]) {
            if let name=result.node.name,let action=actions[name] {
                let now=ProcessInfo.processInfo.systemUptime
                guard now-lastTap>0.35 else { return true };lastTap=now
                UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action);return true
            }
            if result.node===root || result.node.parent===root { return true }
        }
        return false
    }
    private func activate(_ action: SpatialPanelAction) {
        switch action {
        case .module(let target): open(target,tracking:true)
        case .close: close()
        case .reposition: reposition()
        case .page(let delta): offset=max(0,offset+delta);request("library")
        case .refresh: request("library")
        case .spotify(let action,let playlist): request(action,playlist:playlist)
        default: onAction?(action)
        }
    }
    func request(_ action: String, playlist: String? = nil) {
        guard pending==nil else { status="Aguarde a confirmação do pedido anterior.";render();return }
        let id=UUID().uuidString;pending=id;status="Consultando o Spotify…";render()
        var job: [String:Any]=["requestId":id,"action":action,"offset":offset]
        if let playlist { job["playlistId"]=playlist }
        onSpotify?(job)
        timeout?.cancel();timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(30))
            guard !Task.isCancelled,let self,self.pending==id else { return }
            self.pending=nil;self.status="A ponte não confirmou. Verifique a conexão; não repeti a ação.";self.render()
        }
    }
    func receive(_ data: Data) {
        guard let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let id=result["requestId"] as? String,id==pending else { return }
        pending=nil;timeout?.cancel();status=result["message"] as? String ?? "Consulta concluída."
        if let rows=result["playlists"] as? [[String:Any]] {
            playlists=rows.compactMap { row in
                guard let id=row["id"] as? String,let name=row["name"] as? String else { return nil };return (id,name)
            }
            offset=result["offset"] as? Int ?? 0;hasNext=result["hasNext"] as? Bool ?? false
            if playlists.isEmpty { status="Nenhuma playlist nesta página. \(status)" }
        }
        render()
    }
    func showResult(_ text: String) { guard visible else { return };status=String(text.prefix(190));render() }

    #if DEBUG
    /// Render the actual cards in tests without pretending the simulator has LiDAR.
    func preview(_ destination: SpatialModule) {
        close();module=destination;visible=true
        let node=SCNNode();root=node;view.scene.rootNode.addChildNode(node);render()
    }
    #endif

    private func items() -> [(String,String,SpatialPanelAction)] {
        switch module {
        case .dashboard:
            return SpatialModule.allCases.filter{$0 != .dashboard}.map { ($0.title,$0.symbol,.module($0)) }
        case .spotify:
            var rows: [(String,String,SpatialPanelAction)]=playlists.map { ($0.name,"music.note.list",.spotify("play",$0.id)) }
            rows += [("Pausar","pause.fill",.spotify("pause",nil)),("Próxima","forward.end.fill",.spotify("next",nil)),("Anterior","backward.end.fill",.spotify("previous",nil)),("Atualizar","arrow.clockwise",.refresh)]
            if offset>0 { rows.append(("Página anterior","chevron.left",.page(-6))) }
            if hasNext { rows.append(("Mais playlists","chevron.right",.page(6))) }
            return rows
        case .phone:
            return [("Acender lanterna","flashlight.on.fill",.command("ligue a lanterna do iPhone")),("Apagar lanterna","flashlight.off.fill",.command("desligue a lanterna do iPhone")),("Tela 30%","sun.min",.command("ajuste o brilho do iPhone para 30%")),("Tela 70%","sun.max",.command("ajuste o brilho do iPhone para 70%")),("Volume 20%","speaker.wave.1",.command("volume do iPhone em 20%")),("Volume 60%","speaker.wave.2",.command("volume do iPhone em 60%")),("Bateria","battery.100",.command("qual a bateria do iPhone")),("Abrir Spotify","arrow.up.right",.command("configurar spotify deste iphone"))]
        case .home:
            return [("Acender luz","lightbulb",.command("ligue a luz")),("Apagar luz","lightbulb.slash",.command("apague a luz")),("Lâmpada 25%","sun.min",.command("brilho da lâmpada em 25%")),("Lâmpada 75%","sun.max",.command("brilho da lâmpada em 75%")),("Luz azul","circle.fill",.command("deixe a lâmpada azul em 50%")),("Luz quente","sun.haze",.command("deixe a lâmpada branco quente em 50%")),("Ligar cafeteira","cup.and.saucer",.command("ligue a cafeteira")),("Desligar cafeteira","power",.command("desligue a cafeteira")),("Consultar aparelhos","list.bullet",.command("liste meus dispositivos da casa"))]
        case .camera:
            return [("O que estou vendo?","viewfinder",.command("o que estou vendo")),("Visão contínua","video",.command("ativar visão contínua")),("Traduzir câmera","character.bubble",.studio("translate"))]
        case .creation:
            return [("Desenhar","pencil.tip",.studio("sketch")),("Gerar imagem por voz","photo",.command("gere uma imagem")),("Objetos e cenários","cube",.module(.scenes))]
        case .scenes:
            return SpatialTheme.allCases.map { ($0.title,$0.symbol,.scene($0)) }
        case .instruments:
            return [("Harpa","music.note",.command("abrir harpa")),("Violão","guitars",.command("abrir violão")),("Guitarra","guitars.fill",.command("abrir guitarra"))]
        case .libras:return [("Abrir reconhecimento","hands.sparkles",.studio("libras"))]
        case .translation:return [("Abrir tradutor","character.bubble",.studio("translate"))]
        case .personal:
            return [("Hora","clock",.command("que horas são")),("Passos hoje","figure.walk",.command("quantos passos hoje")),("Clima","cloud.sun",.command("como está o tempo aqui")),("Minha agenda","calendar",.command("leia minha agenda de hoje")),("Último e-mail","envelope",.command("leia meu último email"))]
        }
    }
    private func render() {
        guard let root else { return };root.childNodes.forEach { $0.removeFromParentNode() };actions.removeAll()
        let rows=items(), columns=2, rowCount=max(1,(rows.count+columns-1)/columns)
        let width:CGFloat=0.76, height:CGFloat=0.24+CGFloat(rowCount)*0.087
        func plate(_ title: String,_ icon: String,width:CGFloat,height:CGFloat,x:Float,y:Float,color:UIColor,action:SpatialPanelAction?=nil) {
            let format=UIGraphicsImageRendererFormat();format.scale=2
            let size=CGSize(width:width*1500,height:height*1500)
            let image=UIGraphicsImageRenderer(size:size,format:format).image { context in
                color.setFill();UIBezierPath(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:18).fill()
                let font=UIFont.systemFont(ofSize:height<0.09 ? 25 : 29,weight:.semibold)
                if let symbol=UIImage(systemName:icon,withConfiguration:UIImage.SymbolConfiguration(pointSize:28,weight:.medium))?.withTintColor(.cyan,renderingMode:.alwaysOriginal) {
                    symbol.draw(in:CGRect(x:20,y:(size.height-32)/2,width:32,height:32))
                }
                let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in:CGRect(x:icon.isEmpty ? 20 : 65,y:14,width:size.width-(icon.isEmpty ? 40 : 82),height:size.height-24),withAttributes:[.font:font,.foregroundColor:UIColor.white,.paragraphStyle:paragraph])
            }
            let geometry=SCNPlane(width:width,height:height);geometry.cornerRadius=0.008
            let material=SCNMaterial();material.diffuse.contents=image;material.lightingModel = .constant;material.isDoubleSided=false
            geometry.materials=[material]
            let node=SCNNode(geometry:geometry);node.position=SCNVector3(x,y,0.008)
            if let action { let id=UUID().uuidString;node.name=id;actions[id]=action }
            root.addChildNode(node)
        }
        let back=SCNNode(geometry:SCNBox(width:width+0.035,height:height+0.035,length:0.012,chamferRadius:0.015))
        back.geometry?.firstMaterial?.diffuse.contents=UIColor(red:0.018,green:0.04,blue:0.06,alpha:1);back.geometry?.firstMaterial?.lightingModel = .constant
        root.addChildNode(back)
        let top=Float(height/2)
        plate(module.title,module.symbol,width:width-0.17,height:0.065,x:-0.08,y:top-0.04,color:.clear,action:.module(.dashboard))
        plate("","xmark",width:0.07,height:0.065,x:0.33,y:top-0.04,color:.clear,action:.close)
        for (i,row) in rows.enumerated() {
            plate(row.0,row.1,width:0.36,height:0.075,x:i%2==0 ? -0.19 : 0.19,y:top-0.13-Float(i/2)*0.087,
                  color:UIColor(red:0.045,green:0.12,blue:0.16,alpha:1),action:row.2)
        }
        plate(status,"",width:width,height:0.075,x:0,y:-top+0.05,color:.clear)
    }
}
