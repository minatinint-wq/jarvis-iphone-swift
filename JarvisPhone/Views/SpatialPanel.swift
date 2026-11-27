import SwiftUI
import ARKit
import SceneKit

enum SpatialPanelGeometry {
    @MainActor static func framed(_ root: SCNNode,in view: ARSCNView,size: CGSize) -> Bool {
        guard let frame=view.session.currentFrame else { return false }
        let delta=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)-root.simdWorldPosition
        let normal=SIMD3(root.simdWorldTransform.columns.2.x,root.simdWorldTransform.columns.2.y,root.simdWorldTransform.columns.2.z)
        guard simd_length(delta)>0.01,simd_dot(simd_normalize(delta),simd_normalize(normal))>0.65 else { return false }
        let center=view.projectPoint(root.worldPosition),top=view.projectPoint(root.convertPosition(SCNVector3(0,0.1,0),to:nil))
        guard top.y<center.y,abs(top.x-center.x)<abs(top.y-center.y)*0.6 else { return false }
        return ([-Float(size.width/2),Float(size.width/2)]).allSatisfy { x in [-Float(size.height/2),Float(size.height/2)].allSatisfy { y in
            let point=view.projectPoint(root.convertPosition(SCNVector3(x,y,0),to:nil))
            return point.z>0 && point.z<1 && view.bounds.insetBy(dx:12,dy:12).contains(CGPoint(x:CGFloat(point.x),y:CGFloat(point.y)))
        }}
    }
    /// Intersect the card plane directly. Depth-only meshes must never absorb UI input.
    static func localHit(origin:SIMD3<Float>,direction:SIMD3<Float>,transform:simd_float4x4)->SIMD2<Float>? {
        let inverse=simd_inverse(transform),o=inverse*SIMD4(origin,1),d=inverse*SIMD4(direction,0)
        guard abs(d.z)>0.0001 else { return nil }
        let t=(Float(0.008)-o.z)/d.z
        guard t>=0,t.isFinite else { return nil }
        let p=o+d*t
        guard p.x.isFinite,p.y.isFinite,abs(p.x)<=0.33,abs(p.y)<=0.30 else { return nil }
        return SIMD2(p.x,p.y)
    }
    static let size=CGSize(width:0.64,height:0.58)
    /// Gravity defines up. Camera sensor X/Y axes rotate with portrait orientation.
    static func upright(camera:simd_float4x4,distance:Float) -> simd_float4x4? {
        let back=SIMD3<Float>(camera.columns.2.x,0,camera.columns.2.z)
        // Near the ceiling the horizontal heading is undefined. Face the screen.
        if abs(camera.columns.2.y) > 0.78 {
            var pose = camera
            pose.columns.3 = camera.columns.3 - camera.columns.2 * distance
            return pose
        }
        guard simd_length(back)>0.2 else { return nil }
        let z=simd_normalize(back),y=SIMD3<Float>(0,1,0),x=simd_cross(y,z)
        let position=camera.columns.3-camera.columns.2*distance
        return simd_float4x4(SIMD4(x.x,x.y,x.z,0),SIMD4(y.x,y.y,y.z,0),SIMD4(z.x,z.y,z.z,0),SIMD4(position.x,position.y,position.z,1))
    }
    static func projectedBounds(transform:simd_float4x4,scale:Float,view:simd_float4x4,projection:simd_float4x4,viewport:CGSize)->CGRect? {
        var points:[CGPoint]=[]
        for x in [-0.33,0.33] as [Float] { for y in [-0.30,0.30] as [Float] {
            let p=projection*view*transform*SIMD4<Float>(x*scale,y*scale,0,1)
            guard p.w>0,p.x.isFinite,p.y.isFinite else { return nil }
            points.append(CGPoint(x:CGFloat(p.x/p.w+1)*viewport.width/2,y:CGFloat(1-p.y/p.w)*viewport.height/2))
        } }
        let xs=points.map(\.x),ys=points.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
    static func fittedScale(transform:simd_float4x4,view:simd_float4x4,projection:simd_float4x4,viewport:CGSize,maximum:Float=0.70)->Float? {
        let safe=CGRect(x:viewport.width*0.12,y:max(76,viewport.height*0.12),width:viewport.width*0.76,height:viewport.height-max(76,viewport.height*0.12)-max(136,viewport.height*0.20))
        var scale=maximum
        while scale>=0.20 {
            if let bounds=projectedBounds(transform:transform,scale:scale,view:view,projection:projection,viewport:viewport),safe.contains(bounds) { return scale }
            scale *= 0.93
        }
        return nil
    }
}

/// An anchored spatial dashboard. Tap targets are separate real SceneKit nodes;
/// the content is drawn crisply into textures, not a screenshot floating in UI.
@MainActor final class SpatialPanel: ObservableObject {
    @Published var visible=false
    @Published private(set) var immersive=false
    private var compact=false
    private var radialExpanded=false
    private var radialIndex=0
    private var effectsCatalog=false
    var showingEffectsCatalog:Bool { visible && effectsCatalog && radialExpanded }
    func openEffectsRadial(tracking:Bool) {
        open(.dashboard,tracking:tracking)
        guard tracking,visible else { return }
        // An explicit summoning gesture brings the catalog into view once.
        reposition()
        effectsCatalog=true;immersive=true;compact=true;radialExpanded=true;radialIndex=0
        status="Catálogo de efeitos · solte a mão e aponte por dois segundos para escolher."
        render();onChange?()
    }
    func cleanInterface() {
        guard visible,root != nil else { return }
        immersive=true;compact=true;radialExpanded=false;radialIndex=0
        render()
    }
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
    private var cardPage=0
    private var pending: String?
    private var contextRevision=0
    private var trackingGood=false
    private var navigationContext: (revision:Int, actions:[SpatialPanelAction])?
    private var timeout: Task<Void,Never>?
    private var lastTap: TimeInterval=0
    private var handGesture=SpatialGesture()
    var dwellProgress: Double { handGesture.progress }
    private weak var hovered:SCNNode?
    private var dragOffset=SIMD3<Float>.zero
    private var dragDepth:Float=0
    private var dragging=false
    var isDragging: Bool { dragging }
    private var palmScale=SpatialPalmScale()
    private var palmCalibration=SpatialPalmCalibration()
    private var pinchZoom=SpatialPinchZoom()
    private func handDepth(_ sample:SpatialHandSample) -> Double? {
        guard let frame=view.session.currentFrame,let palm=sample.palmWorld else { return nil }
        let p=frame.camera.transform.columns.3
        return Double(simd_distance(SIMD3(p.x,p.y,p.z),palm))
    }
    private var swipe = SpatialPageSwipe()
    private var pcOutput = (UserDefaults.standard.string(forKey:"spatialSpotifyOutput") ?? "pc") == "pc"
    var onWeb: ((SpatialModule)->Void)?
    var onChange: (() -> Void)?
    private var needsSpotify = false
    var onAction: ((SpatialPanelAction)->Void)?
    var onSpotify: (([String:Any])->Void)?
    init(view: ARSCNView) { self.view=view }

    func open(_ destination: SpatialModule, tracking: Bool, page: Int = 0) {
        let destination=destination.canonical
        if destination == .youtube || destination == .browser { close(); onWeb?(destination); return }
        contextRevision += 1
        trackingGood=tracking
        guard tracking else { status="Aguarde o mapeamento estabilizar e abra o painel novamente.";return }
        module=destination;compact=false;radialExpanded=false;effectsCatalog=false
        cardPage=max(0,page)
        if root == nil { reposition() }
        guard root != nil else { return }
        visible=true;root?.isHidden=false;status="\(destination.title) · escolha uma ação."
        render()
        onChange?()
        if destination == .spotify { refreshPage() }
    }
    func reposition() {
        guard let frame=view.session.currentFrame else { return }
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let camera=simd_inverse(frame.camera.viewMatrix(for:orientation))
        var distance:Float=0.55
        if let query=view.raycastQuery(from:CGPoint(x:view.bounds.midX,y:view.bounds.midY),allowing:.existingPlaneGeometry,alignment:.any),
           let hit=view.session.raycast(query).first {
            let gap=simd_distance(SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z),SIMD3(camera.columns.3.x,camera.columns.3.y,camera.columns.3.z))-0.18
            guard gap>=0.45 else { status="Aponte para um espaço livre, afastado da parede e da mão.";return }
            distance=min(distance,gap)
        }
        guard let transform=SpatialPanelGeometry.upright(camera:camera,distance:distance),
              let scale=SpatialPanelGeometry.fittedScale(transform:transform,view:frame.camera.viewMatrix(for:orientation),projection:frame.camera.projectionMatrix(for:orientation,viewportSize:view.bounds.size,zNear:0.01,zFar:20),viewport:view.bounds.size) else {
            status="Aponte o iPhone para frente para posicionar um painel vertical.";return
        }
        guard clearSpace(transform:transform,scale:scale) else { status="Há uma superfície ocupando o painel. Aponte para uma área livre e toque em Centralizar.";return }
        if let anchor { view.session.remove(anchor:anchor) };root?.removeFromParentNode()
        let anchor=ARAnchor(name:"JarvisControlPanel",transform:transform)
        let root=SCNNode();root.simdTransform=transform
        root.simdScale=SIMD3<Float>(repeating:scale)
        self.anchor=anchor;self.root=root;view.scene.rootNode.addChildNode(root);view.session.add(anchor:anchor)
        render()
        onChange?()
    }
    private func clearSpace(transform:simd_float4x4,scale:Float)->Bool {
        guard let frame=view.session.currentFrame else { return false }
        let origin=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        for x in [-0.32,0,0.32] as [Float] { for y in [-0.29,0,0.29] as [Float] {
            let p=transform*SIMD4<Float>(x*scale,y*scale,0,1),destination=SIMD3(p.x,p.y,p.z)
            let screen=view.projectPoint(SCNVector3(p.x,p.y,p.z))
            guard let query=view.raycastQuery(from:CGPoint(x:CGFloat(screen.x),y:CGFloat(screen.y)),allowing:.existingPlaneGeometry,alignment:.any) else { continue }
            if let hit=view.session.raycast(query).first {
                let obstacle=SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z)
                if simd_distance(origin,destination)>simd_distance(origin,obstacle)-0.10 { return false }
            }
        } }
        return true
    }
    func resize(_ multiplier:Float) {
        guard let root else { return }
        let next=min(0.70,max(0.20,root.simdScale.x*multiplier))
        var transform=root.simdWorldTransform
        for i in 0..<3 { let c=transform[i],v=simd_normalize(SIMD3(c.x,c.y,c.z));transform[i]=SIMD4(v.x,v.y,v.z,0) }
        if clearSpace(transform:transform,scale:next) { root.simdScale=SIMD3(repeating:next);onChange?() }
    }
    func update(_ updated: ARAnchor) {
        if updated.identifier==anchor?.identifier {
            let scale=root?.simdScale ?? SIMD3<Float>(repeating:1)
            anchor=updated;root?.simdTransform=updated.transform;root?.simdScale=scale
        }
    }
    func snapshot() -> SpatialPanelRecord? {
        guard visible,!dragging,let anchor,let root else { return nil }
        return SpatialPanelRecord(anchor:anchor.identifier,module:module.rawValue,scale:root.simdScale.x)
    }
    func restore(_ saved: SpatialPanelRecord, anchor: ARAnchor) {
        guard root == nil,let destination=SpatialModule(rawValue:saved.module),destination != .browser,destination != .youtube else { return }
        let node=SCNNode();node.simdTransform=anchor.transform;node.simdScale=SIMD3(repeating:saved.scale);node.isHidden=true
        root=node;self.anchor=anchor;module=destination;visible=true
        view.scene.rootNode.addChildNode(node);render()
        status="Painel salvo. Aguarde a relocalização estabilizar."
    }
    func setTracking(_ good: Bool) {
        trackingGood=good
        if !good { swipe=SpatialPageSwipe(); if dragging { finishDrag() };handGesture.reset() }
        root?.isHidden = !good || !visible
    }
    func close(recordChange: Bool = true,preserveAnchor:Bool = false) {
        if recordChange,root != nil { onChange?() }
        contextRevision += 1;navigationContext=nil
        handGesture.reset();swipe=SpatialPageSwipe();dragging=false;hovered=nil
        timeout?.cancel();pending=nil;visible=false;immersive=false;compact=false;radialExpanded=false
        if !preserveAnchor,let anchor { view.session.remove(anchor:anchor) };anchor=nil
        root?.removeFromParentNode();root=nil;actions.removeAll()
    }
    private func localHit(_ point:CGPoint)->SIMD2<Float>? {
        guard let root else { return nil }
        let a=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),0)),b=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),1))
        return SpatialPanelGeometry.localHit(origin:SIMD3(a.x,a.y,a.z),direction:SIMD3(b.x-a.x,b.y-a.y,b.z-a.z),transform:root.simdWorldTransform)
    }
    func contains(_ point: CGPoint) -> Bool { visible && root?.isHidden == false && (compact ? selectionNode(point) != nil : localHit(point) != nil) }
    var isFramed: Bool {
        guard visible,let root else { return false };return SpatialPanelGeometry.framed(root,in:view,size:compact && !radialExpanded ? CGSize(width:0.10,height:0.10) : CGSize(width:0.64,height:0.58))
    }
    private func selectionNode(_ point:CGPoint)->SCNNode? {
        guard let p=localHit(point),let root else { return nil }
        return root.childNodes.first { node in
            guard let name=node.name,actions[name] != nil else { return false }
            if let plane=node.geometry as? SCNPlane {
                return abs(p.x-node.position.x)<=Float(plane.width)/2 && abs(p.y-node.position.y)<=Float(plane.height)/2
            }
            if let sector=node.geometry as? SCNShape {
                return sector.path?.contains(CGPoint(x:CGFloat(p.x-node.position.x),y:CGFloat(p.y-node.position.y))) == true
            }
            return false
        }
    }
    func hit(_ point: CGPoint) -> Bool {
        guard visible,root?.isHidden==false,localHit(point) != nil else { return false }
        if let name=selectionNode(point)?.name,let action=actions[name] {
            let now=ProcessInfo.processInfo.systemUptime
            guard now-lastTap>0.35 else { return true };lastTap=now
            UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action)
        }
        return true
    }
    func hand(_ sample:SpatialHandSample?) {
        guard visible,root?.isHidden==false else { handGesture.reset();return }
        let time=sample?.time ?? ProcessInfo.processInfo.systemUptime
        // Open palm is a free hand, never an implicit resize operation.
        palmScale=SpatialPalmScale();palmCalibration=SpatialPalmCalibration()
        if let sample, sample.menuPose, sample.ratio >= 0.48, !dragging, view.bounds.width > 0, view.bounds.height > 0 {
            handGesture.reset()
            let pos=CGPoint(x:sample.point.x/view.bounds.width,y:sample.point.y/view.bounds.height)
            if let page=swipe.update(point:pos,time:time), pending == nil { activate(.cardsPage(page)) }
            return
        }
        swipe=SpatialPageSwipe()
        let node=sample.flatMap { selectionNode($0.point) }
        let target=node?.name.flatMap { actions[$0] == nil ? nil : $0 }
        if hovered !== node {
            hovered?.scale=SCNVector3(1,1,1);hovered=target == nil ? nil : node;hovered?.scale=SCNVector3(1.025,1.025,1)
        }
        let overPanel = compact ? node != nil : sample.flatMap { localHit($0.point) } != nil
        let hit = target ?? (overPanel ? "panel-surface" : nil)
        let canClick = target.flatMap { actions[$0] }.map { action -> Bool in
            if case .dragHandle = action { return false }
            return true
        } ?? false
        for event in handGesture.update(ratio:sample?.ratio ?? .nan,pointing:sample?.pointing == true && canClick,target:hit,time:time) {
            switch event {
            case .press:
                guard let root,let sample else { continue }
                dragDepth=view.projectPoint(root.worldPosition).z
                let p=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),dragDepth))
                dragOffset=root.simdWorldPosition-SIMD3(p.x,p.y,p.z);dragging=false
                pinchZoom.begin(span:sample.palmSpan,depth:handDepth(sample),time:sample.time)
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
                var proposed=root.simdWorldTransform
                for i in 0..<3 { let c=proposed[i],v=simd_normalize(SIMD3(c.x,c.y,c.z));proposed[i]=SIMD4(v.x,v.y,v.z,0) }
                proposed.columns.3=SIMD4(destination.x,destination.y,destination.z,1)
                if clearSpace(transform:proposed,scale:root.simdScale.x) { root.simdWorldPosition=destination }
            case .release:
                pinchZoom=SpatialPinchZoom()
                if dragging { finishDrag() }
            case .click(let id):
                if let action=actions[id] { UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action) }
            case .cancel: pinchZoom=SpatialPinchZoom();if dragging { finishDrag() }
            }
        }
    }
    private func finishDrag() {
        guard let root else { return };dragging=false
        var transform=root.simdWorldTransform
        for i in 0..<3 { let c=transform[i];let v=simd_normalize(SIMD3<Float>(c.x,c.y,c.z));transform[i]=SIMD4(v.x,v.y,v.z,0) }
        let next=ARAnchor(name:"JarvisControlPanel",transform:transform);anchor=next;view.session.add(anchor:next)
        onChange?()
    }
    private func activate(_ action: SpatialPanelAction) {
        contextRevision += 1
        switch action {
        case .hideInterface: cleanInterface()
        case .radialToggle: radialExpanded.toggle();render()
        case .radialPage(let direction):
            radialIndex=(radialIndex+direction+radialPageCount)%radialPageCount;render()
        case .showInterface: immersive=false;compact=false;radialExpanded=false;render()
        case .switchOutput:
            guard pending == nil else { return }
            pcOutput.toggle()
            UserDefaults.standard.set(pcOutput ? "pc" : "phone",forKey:"spatialSpotifyOutput")
            needsSpotify=false
            status=pcOutput ? "Saída selecionada: este PC." : "Saída selecionada: este iPhone."
            render()
        case .dragHandle: break
        case .cardsPage(let delta):cardPage=max(0,min(max(0,(items().count-1)/4),cardPage+delta));render()
        case .module(let target): open(target,tracking:true)
        case .close: close()
        case .reposition: reposition()
        case .playlist(let id,let name):
            guard pending==nil else { return };cardPage=0;selectedPlaylist=(id,name);selectedTrack=nil;tracks=[];offset=0;hasNext=false;request("tracks",playlist:id)
        case .track(let id,let name): selectedTrack=(id,name);status="Selecionada: \(name). Aperte Play.";render()
        case .library: guard pending==nil else { return };cardPage=0;selectedPlaylist=nil;selectedTrack=nil;tracks=[];offset=0;request("library")
        case .playSelection:
            if let selectedTrack,let selectedPlaylist { request("play_track",playlist:selectedPlaylist.id,track:selectedTrack.id) }
            else if let selectedPlaylist { request("play",playlist:selectedPlaylist.id) }
            else { request("resume") }
        case .page(let delta): guard pending==nil else { return };cardPage=0;offset=max(0,offset+delta);refreshPage()
        case .refresh: refreshPage()
        case .spotify(let action,let playlist): request(action,playlist:playlist)
        default:
            if compact { radialExpanded=false;render() }
            onAction?(action)
        }
    }
    private func refreshPage() { request(selectedPlaylist == nil ? "library" : "tracks",playlist:selectedPlaylist?.id) }
    func interpret(_ text:String) {
        guard pending==nil else { status="Aguarde a confirmação do pedido anterior.";render();return }
        let rows=visibleItems(),id=UUID().uuidString
        navigationContext=(contextRevision,rows.map{$0.2});pending=id
        status="Interpretando seu pedido…";render()
        let cards:[[String:String]]=rows.map { row in
            let kind:String
            switch row.2 {
            case .editor,.instrument,.model,.scene,.module,.playlist,.track,.library,.page,.cardsPage,.dragHandle,.refresh,.reposition,.close:kind="navigation"
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
        var job: [String:Any]=["requestId":id,"action":action,"offset":offset,"output":pcOutput ? "pc" : "phone"]
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
        needsSpotify = result["needsSpotify"] as? Bool == true
        if needsSpotify { cardPage = 0 }
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
    func showResult(_ text: String) { guard visible else { return };status=String(text.prefix(190)) }

    #if DEBUG
    /// Render the actual cards in tests without pretending the simulator has LiDAR.
    func preview(_ destination: SpatialModule) {
        close();cardPage=0;module=destination;visible=true
        let node=SCNNode();root=node;view.scene.rootNode.addChildNode(node);render()
    }
    func previewEffectsCatalog() {
        preview(.dashboard);effectsCatalog=true;compact=true;immersive=true;radialExpanded=true;radialIndex=0;render()
    }
    #endif

    func directory(_ query:String) -> [SpatialDirectoryEntry] {
        let text=PhoneIntentPhrases.normalized(query)
        var results:[SpatialDirectoryEntry]=[]
        for destination in SpatialModule.navigationCases where destination != .dashboard {
            if text.isEmpty || PhoneIntentPhrases.normalized(destination.title).contains(text) {
                results.append(.init(module:destination,title:destination.title,index:nil))
            }
            if text.isEmpty { continue }
            for (index,card) in items(for:destination).enumerated() where PhoneIntentPhrases.normalized(card.0).contains(text) {
                results.append(.init(module:destination,title:card.0,index:index))
            }
        }
        return results
    }
    private func items() -> [(String,String,SpatialPanelAction)] { items(for:module) }
    private func items(for destination: SpatialModule) -> [(String,String,SpatialPanelAction)] {
        switch destination {
        case .dashboard:
            return SpatialModule.navigationCases.filter{$0 != .dashboard}.map { ($0.title,$0.symbol,.module($0)) }
        case .browser,.youtube:return []
        case .network, .system, .apps:
            let controls:[PhoneAction]
            switch destination {
            case .network: controls=[.wifiOn,.wifiOff,.bluetoothOn,.bluetoothOff,.cellularOn,.cellularOff]
            case .system: controls=[.lowPower,.lowPowerOff,.rotationLock,.rotationUnlock,.meeting,.endMeeting,.lock,.shortcutCheck]
            default: controls=[.wallet,.location,.whatsapp,.instagram]
            }
            return controls.map { ($0.title,$0.symbol,.systemAction($0)) }
        case .notebook:
            return [("Nova nota","square.and.pencil",.editor(.note)),("Minhas notas","note.text",.editor(.notes)),("Criar lembrete","checklist",.editor(.reminder))]
        case .commands:
            return [("Hora","clock",.command("que horas são")),("Passos hoje","figure.walk",.command("quantos passos hoje")),("Ligar lanterna","flashlight.on.fill",.command("ligue a lanterna do iPhone")),("Desligar lanterna","flashlight.off.fill",.command("desligue a lanterna do iPhone"))]
        case .spotify:
            var rows: [(String,String,SpatialPanelAction)]=selectedPlaylist == nil
                ? playlists.map { ($0.name,"music.note.list",.playlist($0.id,$0.name)) }
                : tracks.map { ($0.name,$0.id==selectedTrack?.id ? "checkmark.circle.fill" : "music.note",.track($0.id,$0.name)) }
            rows.append(selectedPlaylist == nil ? ("Atualizar","arrow.clockwise",.refresh) : ("Minhas playlists","chevron.left",.library))
            if offset>0 { rows.append(("Página anterior","chevron.left",.page(-6))) }
            if hasNext { rows.append((selectedPlaylist == nil ? "Mais playlists" : "Mais faixas","chevron.right",.page(6))) }
            if needsSpotify && !pcOutput { rows.insert(("Ativar Spotify no iPhone","iphone",.activateSpotify),at:0) }
            return rows
        case .phone:
            return [("Acender lanterna","flashlight.on.fill",.command("ligue a lanterna do iPhone")),("Apagar lanterna","flashlight.off.fill",.command("desligue a lanterna do iPhone")),("Tela 30%","sun.min",.command("ajuste o brilho do iPhone para 30%")),("Tela 70%","sun.max",.command("ajuste o brilho do iPhone para 70%")),("Volume 20%","speaker.wave.1",.command("volume do iPhone em 20%")),("Volume 60%","speaker.wave.2",.command("volume do iPhone em 60%")),("Bateria","battery.100",.command("qual a bateria do iPhone")),("Abrir Spotify","arrow.up.right",.command("configurar spotify deste iphone"))]
        case .home:
            return [("Acender luz","lightbulb",.command("ligue a luz")),("Apagar luz","lightbulb.slash",.command("apague a luz")),("Lâmpada 25%","sun.min",.command("brilho da lâmpada em 25%")),("Lâmpada 75%","sun.max",.command("brilho da lâmpada em 75%")),("Luz azul","circle.fill",.command("deixe a lâmpada azul em 50%")),("Luz quente","sun.haze",.command("deixe a lâmpada branco quente em 50%")),("Ligar cafeteira","cup.and.saucer",.command("ligue a cafeteira")),("Desligar cafeteira","power",.command("desligue a cafeteira")),("Consultar aparelhos","list.bullet",.command("liste meus dispositivos da casa"))]
        case .camera:
            return [("O que estou vendo?","viewfinder",.command("o que estou vendo")),("Visão contínua","video",.command("ativar visão ao vivo")),("Traduzir câmera","character.bubble",.studio("translate"))]
        case .creation:
            return [("Desenhar","pencil.tip",.studio("sketch")),("Gerar imagem por voz","photo",.command("gere uma imagem")),("Objetos e cenários","cube",.module(.scenes))]
        case .scenes,.walls:
            return [("Portal na parede","door.left.hand.open",.wall(.portal)),("Fechar portal","xmark",.wall(.closePortal)),
                    ("Parede branca","paintbrush",.wall(.roomWall("white"))),("Tijolos","square.grid.3x3",.wall(.roomWall("brick"))),
                    ("Marcar parede","ruler",.wall(.measure)),("Adicionar ponto","plus.circle",.wall(.point)),
                    ("Excluir porta ou móvel","rectangle.dashed",.wall(.opening)),("Aplicar recorte","checkmark",.wall(.approve)),
                    ("Comparar pintura","eye",.wall(.compare)),("Limpar parede","eraser",.wall(.roomClear)),
                    ("Tela do PC ao vivo","desktopcomputer",.wall(.desktop)),("Salvar ambiente","square.and.arrow.down",.wall(.saveMap))]
                + WallFinish.allCases.map { ($0.title,"paintbrush",.wall(.finish($0))) }
                + SpatialTheme.allCases.map { ($0.title,$0.symbol,.scene($0)) } + SpatialAssets.catalog.map { ($0.title,"cube",.model($0.id)) }
        case .instruments:
            return StudioInstrument.allCases.map { ($0.rawValue,"music.note",.instrument($0)) }
        case .libras:return [("Abrir reconhecimento","hands.sparkles",.studio("libras"))]
        case .translation:return [("Abrir tradutor","character.bubble",.studio("translate"))]
        case .personal:
            return [("Hora","clock",.command("que horas são")),("Passos hoje","figure.walk",.command("quantos passos hoje")),("Clima","cloud.sun",.command("como está o tempo aqui")),("Minha agenda","calendar",.command("leia minha agenda de hoje")),("Último e-mail","envelope",.command("leia meu último email")),("Última prévia recebida","bell",.command("qual a última notificação")),("Previsão de amanhã","cloud.sun",.command("previsão do tempo para amanhã")),("Notas e lembretes","note.text",.module(.notebook))]
        }
    }
    private func transportItems()->[(String,String,SpatialPanelAction)] {
        guard module == .spotify else { return [] }
        return [("Anterior","backward.end.fill",.spotify("previous",nil)),(selectedTrack == nil ? (selectedPlaylist == nil ? "Retomar" : "Tocar playlist") : "Play: "+selectedTrack!.name,"play.fill",.playSelection),("Pausar","pause.fill",.spotify("pause",nil)),("Próxima","forward.end.fill",.spotify("next",nil))]
    }
    private func visibleItems()->[(String,String,SpatialPanelAction)] {
        if compact {
            guard radialExpanded else { return [("Abrir menu radial","circle.grid.2x2.fill",.radialToggle)] }
            return Array(radialItems.dropFirst(radialIndex*6).prefix(6))+[("Recolher menu","sparkles",.radialToggle),("Próxima página","chevron.right",.radialPage(1)),("Mostrar interface","eye",.showInterface)]
        }
        var rows=Array(items().dropFirst(cardPage*4).prefix(4))+transportItems()
        if cardPage>0 { rows.append(("Página anterior de cartões","chevron.left",.cardsPage(-1))) }
        if (cardPage+1)*4<items().count { rows.append(("Mais cartões","chevron.right",.cardsPage(1))) }
        if module == .spotify { rows.append((pcOutput ? "Usar iPhone" : "Usar PC","speaker.wave.2",.switchOutput)) }
        rows.append(("Central JARVIS","square.grid.2x2",.module(.dashboard)))
        return rows
    }
    private var radialItems:[(String,String,SpatialPanelAction)] {
        if effectsCatalog {
            return [("Portal","door.left.hand.open",.wall(.portal)),("Fechar portal","xmark",.wall(.closePortal)),("Branco","paintbrush.fill",.wall(.roomWall("white"))),
                    ("Tijolos","square.grid.3x3.fill",.wall(.roomWall("brick"))),
                    ("Robô","figure.wave",.model("animated_robot")),
                    ("Raposa","pawprint.fill",.model("animated_fox")),
                    ("Bosque","leaf.fill",.scene(.forest)),
                    ("Aquário","water.waves",.scene(.aquarium)),
                    ("Noturno","moon.stars.fill",.scene(.enchanted)),
                    ("Estúdio","hifispeaker.fill",.scene(.studio)),
                    ("Garagem","car.fill",.scene(.garage)),
                    ("Sala","sofa.fill",.scene(.lounge)),
                    ("Limpar parede","eraser.fill",.wall(.roomClear)),
                    ("Módulos","square.grid.2x2",.showInterface)] + SpatialAssets.catalog.filter{!$0.id.hasPrefix("demo_") && !["animated_robot","animated_fox"].contains($0.id)}.map { ($0.title,"cube",.model($0.id)) }
        }
        return SpatialModule.navigationCases.filter { $0 != .dashboard }.map { ($0.title,$0.symbol,.module($0)) }
            + [("Tela do PC","desktopcomputer",.wall(.desktop)),("Mostrar interface","eye",.showInterface)]
    }
    private var radialPageCount:Int { max(1,(radialItems.count+5)/6) }
    private func render() {
        hovered=nil
        guard let root else { return };root.childNodes.forEach { $0.removeFromParentNode() };actions.removeAll()
        cardPage=min(cardPage,max(0,(items().count-1)/4))
        let rows=Array(items().dropFirst(cardPage*4).prefix(4))
        let width:CGFloat=0.64,height:CGFloat=0.58
        func plate(_ title:String,_ icon:String,width:CGFloat,height:CGFloat,x:Float,y:Float,color:UIColor,action:SpatialPanelAction?=nil) {
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let size=CGSize(width:width*1800,height:height*1800)
            let image=UIGraphicsImageRenderer(size:size,format:format).image { _ in
                color.setFill();UIBezierPath(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:20).fill()
                let symbolWidth:CGFloat=title.isEmpty ? 48 : 36
                if let symbol=UIImage(systemName:icon,withConfiguration:UIImage.SymbolConfiguration(pointSize:symbolWidth,weight:.medium))?.withTintColor(.cyan,renderingMode:.alwaysOriginal) {
                    symbol.draw(in:CGRect(x:title.isEmpty ? (size.width-symbolWidth)/2 : 18,y:(size.height-symbolWidth)/2,width:symbolWidth,height:symbolWidth))
                }
                let font=UIFont.systemFont(ofSize:width<0.20 ? 26 : icon.isEmpty ? 30 : 48,weight:.semibold)
                let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
                let left:CGFloat=icon.isEmpty ? 18 : 66,textWidth=max(0,size.width-left-18),textHeight=size.height-24
                let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.white,.paragraphStyle:paragraph]
                let measured=(title as NSString).boundingRect(with:CGSize(width:textWidth,height:textHeight),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes,context:nil)
                let h=min(textHeight,ceil(measured.height))
                (title as NSString).draw(in:CGRect(x:left,y:(size.height-h)/2,width:textWidth,height:h),withAttributes:attributes)
            }
            let geometry=SCNPlane(width:width,height:height);geometry.cornerRadius=0.008
            let material=SCNMaterial();material.diffuse.contents=image;material.lightingModel = .constant;material.isDoubleSided=false
            material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
            material.diffuse.mipFilter = .linear;material.diffuse.maxAnisotropy=8
            geometry.materials=[material]
            let node=SCNNode(geometry:geometry);node.categoryBitMask=4;node.position=SCNVector3(x,y,0.008)
            node.renderingOrder=101
            if let action {
                let id:String
                if case .radialToggle=action { id="immersive-orb" }
                else { id="action:\(title)|\(icon)|\(String(describing:action))" }
                node.name=id;actions[id]=action
            }
            root.addChildNode(node)
        }
        if compact {
            let color=UIColor(red:0.015,green:0.09,blue:0.12,alpha:0.94)
            plate("",radialExpanded ? "sparkles" : "circle.grid.2x2.fill",width:0.09,height:0.09,x:0,y:0,color:color,action:.radialToggle)
            (root.childNodes.last?.geometry as? SCNPlane)?.cornerRadius=0.045
            if radialExpanded {
                for (i,row) in radialItems.dropFirst(radialIndex*6).prefix(6).enumerated() {
                    let angle=Float.pi/2-Float(i)*Float.pi/3
                    let start=CGFloat(angle)-CGFloat.pi/6+0.025,end=CGFloat(angle)+CGFloat.pi/6-0.025
                    let path=UIBezierPath();path.flatness=0.001;path.move(to:CGPoint(x:cos(start)*0.285,y:sin(start)*0.285))
                    for step in 1...20 { let a=start+(end-start)*CGFloat(step)/20;path.addLine(to:CGPoint(x:cos(a)*0.285,y:sin(a)*0.285)) }
                    path.addLine(to:CGPoint(x:cos(end)*0.115,y:sin(end)*0.115))
                    for step in 1...20 { let a=end+(start-end)*CGFloat(step)/20;path.addLine(to:CGPoint(x:cos(a)*0.115,y:sin(a)*0.115)) };path.close()
                    let sector=SCNNode(geometry:SCNShape(path:path,extrusionDepth:0.001))
                    sector.name="radial-sector:\(i)";sector.categoryBitMask=4;sector.position.z=0.006;sector.renderingOrder=100
                    let material=SCNMaterial();material.diffuse.contents=color;material.emission.contents=UIColor(red:0,green:0.03,blue:0.04,alpha:1)
                    material.lightingModel = .constant;material.isDoubleSided=false;material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
                    sector.geometry?.materials=[material];root.addChildNode(sector);actions[sector.name!]=row.2
                    plate(row.0,row.1,width:0.145,height:0.078,x:cos(angle)*0.20,y:sin(angle)*0.20,color:.clear)
                }
                plate("","chevron.left",width:0.05,height:0.055,x:-0.095,y:0,color:color,action:.radialPage(-1))
                plate("","chevron.right",width:0.05,height:0.055,x:0.095,y:0,color:color,action:.radialPage(1))
            }
            return
        }
        let back=SCNNode(geometry:SCNBox(width:width+0.015,height:height+0.015,length:0.012,chamferRadius:0.012));back.categoryBitMask=4
        back.geometry?.firstMaterial?.diffuse.contents=UIColor(red:0.018,green:0.04,blue:0.06,alpha:1);back.geometry?.firstMaterial?.lightingModel = .constant
        back.geometry?.firstMaterial?.readsFromDepthBuffer=false;back.geometry?.firstMaterial?.writesToDepthBuffer=false;back.renderingOrder=100
        root.addChildNode(back)
        let color=UIColor(red:0.045,green:0.12,blue:0.16,alpha:1)
        plate(module.title,"hand.draw",width:0.43,height:0.075,x:-0.095,y:0.24,color:.clear,action:.dragHandle)
        plate("","eye.slash",width:0.07,height:0.075,x:0.175,y:0.24,color:.clear,action:.hideInterface)
        plate("","xmark",width:0.07,height:0.075,x:0.275,y:0.24,color:.clear,action:.close)
        for (i,row) in rows.enumerated() {
            plate(row.0,row.1,width:0.30,height:0.115,x:i%2==0 ? -0.16 : 0.16,y:0.135-Float(i/2)*0.13,color:color,action:row.2)
        }
        for (i,row) in transportItems().enumerated() {
            plate("",row.1,width:0.13,height:0.065,x:-0.225+Float(i)*0.15,y:-0.105,color:color,action:row.2)
        }
        if cardPage>0 { plate("","chevron.left",width:0.09,height:0.065,x:-0.265,y:-0.19,color:color,action:.cardsPage(-1)) }
        let count=max(1,(items().count+3)/4)
        plate("Central · \(cardPage+1)/\(count)","square.grid.2x2",width:0.38,height:0.065,x:0,y:-0.19,color:color,action:.module(.dashboard))
        if cardPage+1<count { plate("","chevron.right",width:0.09,height:0.065,x:0.265,y:-0.19,color:color,action:.cardsPage(1)) }
        if module == .spotify {
            plate(pcOutput ? "Saída: PC · trocar" : "Saída: iPhone · trocar","speaker.wave.2",width:width,height:0.055,x:0,y:-0.255,color:color,action:.switchOutput)
        } else {
            plate("Dois dedos: deslize para mudar de página","",width:width,height:0.055,x:0,y:-0.255,color:.clear)
        }
    }
}
