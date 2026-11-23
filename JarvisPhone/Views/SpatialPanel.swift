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
    private var tracks: [(id:String,name:String)]=[]
    private var selectedPlaylist: (id:String,name:String)?
    private var selectedTrack: (id:String,name:String)?
    private var offset=0
    private var hasNext=false
    private var pending: String?
    private var contextRevision=0
    private var trackingGood=false
    private var navigationContext: (revision:Int, actions:[SpatialPanelAction])?
    private var timeout: Task<Void,Never>?
    private var lastTap: TimeInterval=0
    private var handGesture=SpatialGesture()
    private weak var hovered:SCNNode?
    private var dragOffset=SIMD3<Float>.zero
    private var dragDepth:Float=0
    private var dragging=false
    var onAction: ((SpatialPanelAction)->Void)?
    var onSpotify: (([String:Any])->Void)?
    init(view: ARSCNView) { self.view=view }

    func open(_ destination: SpatialModule, tracking: Bool) {
        contextRevision += 1
        trackingGood=tracking
        guard tracking else { status="Aguarde o mapeamento estabilizar e abra o painel novamente.";return }
        module=destination
        if root == nil { reposition() }
        guard root != nil else { return }
        visible=true;root?.isHidden=false;status="\(destination.title) · escolha uma ação."
        render()
        if destination == .spotify { refreshPage() }
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
    func setTracking(_ good: Bool) {
        trackingGood=good
        if !good { if dragging { finishDrag() };handGesture.reset() }
        root?.isHidden = !good || !visible
    }
    func close() {
        contextRevision += 1;navigationContext=nil
        handGesture.reset();dragging=false;hovered=nil
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
    func hand(_ sample:SpatialHandSample?) {
        guard visible,root?.isHidden==false else { handGesture.reset();return }
        let time=sample?.time ?? ProcessInfo.processInfo.systemUptime
        let result=sample.flatMap { view.hitTest($0.point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue]).first }
        let node=result?.node
        let target=node?.name.flatMap { actions[$0] == nil ? nil : $0 }
        if hovered !== node {
            hovered?.scale=SCNVector3(1,1,1);hovered=target == nil ? nil : node;hovered?.scale=SCNVector3(1.025,1.025,1)
        }
        let normal=root.map { SIMD3<Float>($0.simdWorldTransform.columns.2.x,$0.simdWorldTransform.columns.2.y,$0.simdWorldTransform.columns.2.z) }
        let push=sample?.world.flatMap { p in normal.map { Double(-simd_dot(p,simd_normalize($0))) } }
        for event in handGesture.update(point:sample?.point,ratio:sample?.ratio ?? 1,target:target,push:push,time:time) {
            switch event {
            case .press:
                guard let root,let sample else { continue }
                dragDepth=view.projectPoint(root.worldPosition).z
                let p=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),dragDepth))
                dragOffset=root.simdWorldPosition-SIMD3(p.x,p.y,p.z);dragging=false
            case .drag:
                guard let root,let sample else { continue }
                if !dragging { if let anchor { view.session.remove(anchor:anchor) };anchor=nil;dragging=true }
                let p=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),dragDepth))
                let destination=SIMD3(p.x,p.y,p.z)+dragOffset
                if let frame=view.session.currentFrame,let query=view.raycastQuery(from:sample.point,allowing:.existingPlaneGeometry,alignment:.any),let hit=view.session.raycast(query).first {
                    let camera=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
                    let obstacle=SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z)
                    if simd_distance(camera,destination)>simd_distance(camera,obstacle)-0.1 { continue }
                }
                root.simdWorldPosition=destination
            case .release(let id,let click):
                if dragging { finishDrag() } else if click,let action=actions[id] { UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action) }
            case .poke(let id):
                if let action=actions[id] { UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action) }
            case .cancel: if dragging { finishDrag() }
            }
        }
    }
    private func finishDrag() {
        guard let root else { return };dragging=false
        var transform=root.simdWorldTransform
        for i in 0..<3 { let c=transform[i];let v=simd_normalize(SIMD3<Float>(c.x,c.y,c.z));transform[i]=SIMD4(v.x,v.y,v.z,0) }
        let next=ARAnchor(name:"JarvisControlPanel",transform:transform);anchor=next;view.session.add(anchor:next)
    }
    private func activate(_ action: SpatialPanelAction) {
        contextRevision += 1
        switch action {
        case .module(let target): open(target,tracking:true)
        case .close: close()
        case .reposition: reposition()
        case .playlist(let id,let name):
            guard pending==nil else { return };selectedPlaylist=(id,name);selectedTrack=nil;tracks=[];offset=0;hasNext=false;request("tracks",playlist:id)
        case .track(let id,let name): selectedTrack=(id,name);status="Selecionada: \(name). Aperte Play.";render()
        case .library: guard pending==nil else { return };selectedPlaylist=nil;selectedTrack=nil;tracks=[];offset=0;request("library")
        case .playSelection:
            if let selectedTrack,let selectedPlaylist { request("play_track",playlist:selectedPlaylist.id,track:selectedTrack.id) }
            else { request("resume") }
        case .page(let delta): guard pending==nil else { return };offset=max(0,offset+delta);refreshPage()
        case .refresh: refreshPage()
        case .spotify(let action,let playlist): request(action,playlist:playlist)
        default: onAction?(action)
        }
    }
    private func refreshPage() { request(selectedPlaylist == nil ? "library" : "tracks",playlist:selectedPlaylist?.id) }
    func interpret(_ text:String) {
        guard pending==nil else { status="Aguarde a confirmação do pedido anterior.";render();return }
        let rows=items(),id=UUID().uuidString
        navigationContext=(contextRevision,rows.map{$0.2});pending=id
        status="Interpretando seu pedido…";render()
        let cards:[[String:String]]=rows.map { row in
            let kind:String
            switch row.2 {
            case .module,.playlist,.track,.library,.page,.refresh,.reposition,.close:kind="navigation"
            default:kind="action"
            }
            return ["title":row.0,"kind":kind]
        }
        onSpotify?(["requestId":id,"action":"navigate","utterance":text,"module":module.rawValue,"items":cards])
        timeout?.cancel();timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(30))
            guard !Task.isCancelled,let self,self.pending==id else { return }
            self.pending=nil;self.navigationContext=nil;self.status="Não recebi a interpretação. Tente novamente.";self.render()
        }
    }
    func request(_ action: String, playlist: String? = nil, track:String? = nil) {
        guard pending==nil else { status="Aguarde a confirmação do pedido anterior.";render();return }
        let id=UUID().uuidString;pending=id;status="Consultando o Spotify…";render()
        var job: [String:Any]=["requestId":id,"action":action,"offset":offset]
        if let playlist { job["playlistId"]=playlist }
        if let track { job["trackId"]=track }
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
        if let context=navigationContext {
            navigationContext=nil
            guard context.revision==contextRevision else { status="O painel mudou; descartei o pedido anterior.";render();return }
            guard let navigation=result["navigation"] as? [String:Any],let operation=navigation["operation"] as? String else { render();return }
            switch operation {
            case "open":
                if let value=navigation["module"] as? String,let target=SpatialModule(rawValue:value) { open(target,tracking:trackingGood) }
            case "activate":
                guard trackingGood,visible,let slot=navigation["slot"] as? Int,context.actions.indices.contains(slot) else { status="Abra o painel e aguarde o rastreamento antes de selecionar.";render();return }
                activate(context.actions[slot])
            case "close":close()
            default:status="Diga qual módulo ou cartão você quer abrir.";render()
            }
            return
        }
        if let rows=result["playlists"] as? [[String:Any]] {
            playlists=rows.compactMap { row in
                guard let id=row["id"] as? String,let name=row["name"] as? String else { return nil };return (id,name)
            }
            offset=result["offset"] as? Int ?? 0;hasNext=result["hasNext"] as? Bool ?? false
            if playlists.isEmpty { status="Nenhuma playlist nesta página. \(status)" }
        }
        if let rows=result["tracks"] as? [[String:Any]],result["playlistId"] as? String == selectedPlaylist?.id {
            tracks=rows.compactMap { row in
                guard let id=row["id"] as? String,let name=row["name"] as? String else { return nil }
                return (id,name+" · "+(row["artist"] as? String ?? ""))
            }
            offset=result["offset"] as? Int ?? 0;hasNext=result["hasNext"] as? Bool ?? false
            if tracks.isEmpty { status="Sem faixas disponíveis nesta página. \(status)" }
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
            var rows: [(String,String,SpatialPanelAction)]=selectedPlaylist == nil
                ? playlists.map { ($0.name,"music.note.list",.playlist($0.id,$0.name)) }
                : tracks.map { ($0.name,$0.id==selectedTrack?.id ? "checkmark.circle.fill" : "music.note",.track($0.id,$0.name)) }
            rows += [(selectedTrack == nil ? "Play / retomar" : "Play: "+selectedTrack!.name,"play.fill",.playSelection),("Pausar","pause.fill",.spotify("pause",nil)),("Próxima","forward.end.fill",.spotify("next",nil)),("Anterior","backward.end.fill",.spotify("previous",nil))]
            rows.append(selectedPlaylist == nil ? ("Atualizar","arrow.clockwise",.refresh) : ("Minhas playlists","chevron.left",.library))
            if offset>0 { rows.append(("Página anterior","chevron.left",.page(-6))) }
            if hasNext { rows.append(("Mais playlists","chevron.right",.page(6))) }
            return rows
        case .phone:
            return [("Acender lanterna","flashlight.on.fill",.command("ligue a lanterna do iPhone")),("Apagar lanterna","flashlight.off.fill",.command("desligue a lanterna do iPhone")),("Tela 30%","sun.min",.command("ajuste o brilho do iPhone para 30%")),("Tela 70%","sun.max",.command("ajuste o brilho do iPhone para 70%")),("Volume 20%","speaker.wave.1",.command("volume do iPhone em 20%")),("Volume 60%","speaker.wave.2",.command("volume do iPhone em 60%")),("Bateria","battery.100",.command("qual a bateria do iPhone")),("Abrir Spotify","arrow.up.right",.command("configurar spotify deste iphone"))]
        case .home:
            return [("Acender luz","lightbulb",.command("ligue a luz")),("Apagar luz","lightbulb.slash",.command("apague a luz")),("Lâmpada 25%","sun.min",.command("brilho da lâmpada em 25%")),("Lâmpada 75%","sun.max",.command("brilho da lâmpada em 75%")),("Luz azul","circle.fill",.command("deixe a lâmpada azul em 50%")),("Luz quente","sun.haze",.command("deixe a lâmpada branco quente em 50%")),("Ligar cafeteira","cup.and.saucer",.command("ligue a cafeteira")),("Desligar cafeteira","power",.command("desligue a cafeteira")),("Consultar aparelhos","list.bullet",.command("liste meus dispositivos da casa"))]
        case .camera:
            return [("O que estou vendo?","viewfinder",.command("o que estou vendo")),("Visão contínua","video",.command("ativar visão ao vivo")),("Traduzir câmera","character.bubble",.studio("translate"))]
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
        hovered=nil
        guard let root else { return };root.childNodes.forEach { $0.removeFromParentNode() };actions.removeAll()
        let rows=items(), columns=2, rowCount=max(1,(rows.count+columns-1)/columns)
        let width:CGFloat=0.76, height:CGFloat=0.24+CGFloat(rowCount)*0.087
        func plate(_ title: String,_ icon: String,width:CGFloat,height:CGFloat,x:Float,y:Float,color:UIColor,action:SpatialPanelAction?=nil) {
            let format=UIGraphicsImageRendererFormat();format.scale=2
            let size=CGSize(width:width*1500,height:height*1500)
            let image=UIGraphicsImageRenderer(size:size,format:format).image { context in
                color.setFill();UIBezierPath(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:18).fill()
                let font=UIFont.systemFont(ofSize:icon.isEmpty ? 28 : 36,weight:.semibold)
                if let symbol=UIImage(systemName:icon,withConfiguration:UIImage.SymbolConfiguration(pointSize:28,weight:.medium))?.withTintColor(.cyan,renderingMode:.alwaysOriginal) {
                    symbol.draw(in:CGRect(x:20,y:(size.height-32)/2,width:32,height:32))
                }
                let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
                let textWidth=size.width-(icon.isEmpty ? 40 : 82),textHeight=size.height-24
                let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.white,.paragraphStyle:paragraph]
                let measured=(title as NSString).boundingRect(with:CGSize(width:textWidth,height:textHeight),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes,context:nil)
                let height=min(textHeight,ceil(measured.height))
                (title as NSString).draw(in:CGRect(x:icon.isEmpty ? 20 : 65,y:(size.height-height)/2,width:textWidth,height:height),withAttributes:attributes)
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
        plate(selectedPlaylist != nil && module == .spotify ? selectedPlaylist!.name : module.title,module.symbol,width:width-0.17,height:0.065,x:-0.08,y:top-0.04,color:.clear,action:.module(.dashboard))
        plate("","xmark",width:0.07,height:0.065,x:0.33,y:top-0.04,color:.clear,action:.close)
        for (i,row) in rows.enumerated() {
            plate(row.0,row.1,width:0.36,height:0.075,x:i%2==0 ? -0.19 : 0.19,y:top-0.13-Float(i/2)*0.087,
                  color:UIColor(red:0.045,green:0.12,blue:0.16,alpha:1),action:row.2)
        }
        plate(status,"",width:width,height:0.075,x:0,y:-top+0.05,color:.clear)
    }
}
