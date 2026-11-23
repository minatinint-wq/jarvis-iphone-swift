import ARKit
import SceneKit
import SwiftUI

struct SpatialDesktopRecord: Codable {
    var anchor: UUID
    var scale: Float
}

/// The PC stream changes the texture. Only a deliberate gesture changes its
/// world anchor. Network updates never move the window with the camera.
@MainActor final class SpatialDesktop: ObservableObject {
    @Published var visible=false
    @Published var status="Área de trabalho do PC"
    var send: (([String:Any]) -> Void)?
    var onChange: (() -> Void)?
    var inputBlocked=false { didSet { if inputBlocked { gesture.reset();palmScale=SpatialPalmScale() } } }
    private let view: ARSCNView
    private var root: SCNNode?
    private var screen: SCNPlane?
    private var anchor: ARAnchor?
    private var sequence=0
    private var pending: UUID?
    private var sentAt=0.0
    private var queuedInput: [String:Any]?
    private var loop: Task<Void,Never>?
    private var gesture=SpatialGesture()
    private var palmScale=SpatialPalmScale()
    private var dragging=false
    var isDragging: Bool { dragging }
    private var offset=SIMD3<Float>.zero
    private var dragDepth:Float=0
    private var tracking=false
    var progress: Double { gesture.progress }

    init(view: ARSCNView) { self.view=view }

    func open(tracking: Bool) {
        guard tracking,let frame=view.session.currentFrame else { status="Espere o rastreamento estabilizar.";return }
        if root == nil {
            let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
            let camera=simd_inverse(frame.camera.viewMatrix(for:orientation))
            var distance: Float=0.65
            let center=CGPoint(x:view.bounds.midX,y:view.bounds.midY)
            if let query=view.raycastQuery(from:center,allowing:.existingPlaneGeometry,alignment:.vertical),let surface=view.session.raycast(query).first {
                let p=surface.worldTransform.columns.3-camera.columns.3
                let measured=simd_length(SIMD3(p.x,p.y,p.z))
                if (0.4...2).contains(measured) { distance=max(0.35,measured-0.025) }
            }
            guard let transform=SpatialPanelGeometry.upright(camera:camera,distance:distance) else { return }
            let anchor=ARAnchor(name:"JarvisDesktop",transform:transform)
            build(anchor:anchor,scale:0.7);view.session.add(anchor:anchor);onChange?()
        }
        visible=true;setTracking(tracking);status="Conectando à área de trabalho do PC…"
    }

    private func build(anchor: ARAnchor,scale: Float) {
        let plane=SCNPlane(width:0.64,height:0.36)
        let material=SCNMaterial();material.lightingModel = .constant
        material.diffuse.contents=UIColor(white:0.06,alpha:1)
        material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
        material.diffuse.mipFilter = .linear;material.diffuse.maxAnisotropy=8
        plane.materials=[material]
        let node=SCNNode(geometry:plane);node.categoryBitMask=8;node.renderingOrder=110
        node.simdTransform=anchor.transform;node.simdScale=SIMD3(repeating:scale);node.isHidden=true
        self.anchor=anchor;root=node;screen=plane;view.scene.rootNode.addChildNode(node)
    }

    func restore(_ record: SpatialDesktopRecord,anchor: ARAnchor) {
        guard root == nil else { return }
        build(anchor:anchor,scale:record.scale);visible=true
        status="Tela do PC restaurada. Aguardando posição estável."
    }

    func snapshot() -> SpatialDesktopRecord? {
        guard visible,!dragging,let anchor,let root else { return nil }
        return SpatialDesktopRecord(anchor:anchor.identifier,scale:root.simdScale.x)
    }

    func update(_ anchor: ARAnchor) {
        guard anchor.identifier == self.anchor?.identifier,!dragging,let root else { return }
        let scale=root.simdScale;root.simdTransform=anchor.transform;root.simdScale=scale;self.anchor=anchor
    }

    func setTracking(_ value: Bool) {
        root?.isHidden = !value || !visible
        guard value != tracking || (value && loop == nil && visible) else { return };tracking=value
        if value && visible {
            loop=Task { [weak self] in
                while !Task.isCancelled {
                    guard let self,self.visible,self.tracking else { return }
                    let now=ProcessInfo.processInfo.systemUptime
                    if self.pending != nil,now-self.sentAt>7 { self.pending=nil;self.status="A ponte não atualizou a tela. Tentando reconectar…" }
                    if self.pending == nil { self.request(["action":"frame"]) }
                    try? await Task.sleep(for:.milliseconds(200))
                }
            }
        } else {
            loop?.cancel();loop=nil;gesture.reset();palmScale=SpatialPalmScale();pending=nil;queuedInput=nil
            if dragging { finishDrag() }
            send?(["action":"stop","requestId":UUID().uuidString])
        }
    }

    private func request(_ job: [String:Any]) {
        guard visible,tracking else { return }
        let id=UUID();pending=id;sentAt=ProcessInfo.processInfo.systemUptime
        var packet=job;packet["requestId"]=id.uuidString;packet["sequence"]=sequence;send?(packet)
    }

    func receive(_ bytes: Data) {
        guard let data=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let requestID=data["requestId"] as? String,requestID==pending?.uuidString else { return }
        pending=nil
        guard data["ok"] as? Bool == true else { status=data["message"] as? String ?? "Desktop indisponível.";return }
        if let encoded=data["image"] as? String,encoded.count<350000,let bytes=Data(base64Encoded:encoded),let image=UIImage(data:bytes),
           let width=data["width"] as? Int,let height=data["height"] as? Int,width>0,height>0 {
            screen?.height=0.64*CGFloat(height)/CGFloat(width);screen?.firstMaterial?.diffuse.contents=image
            sequence=data["sequence"] as? Int ?? 0;status="PC ao vivo · indicador por 2 s clica · pinça move a janela"
        }
        if let input=queuedInput { queuedInput=nil;request(input) }
    }

    func input(_ job: [String:Any]) {
        guard sequence>0,visible,tracking else { return }
        if pending != nil { queuedInput=job } else { request(job) }
    }

    private func local(_ point: CGPoint) -> SIMD2<Float>? {
        guard let root,let screen else { return nil }
        let a=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),0)),b=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),1))
        let inverse=simd_inverse(root.simdWorldTransform),o=inverse*SIMD4(a.x,a.y,a.z,1),d=inverse*SIMD4(b.x-a.x,b.y-a.y,b.z-a.z,0)
        guard abs(d.z)>0.0001 else { return nil };let t = -o.z/d.z
        let p=o+d*t
        guard t>=0,abs(p.x)<=0.32,abs(p.y)<=Float(screen.height/2) else { return nil }
        return SIMD2(p.x/0.64+0.5,0.5-p.y/Float(screen.height))
    }
    func tap(_ point: CGPoint) -> Bool {
        guard visible,tracking,let p=local(point) else { return false }
        input(["action":"click","x":Double(p.x),"y":Double(p.y)]);return true
    }

    @discardableResult func hand(_ sample: SpatialHandSample?) -> Bool {
        guard visible,tracking,!inputBlocked,let root else { return false }
        let target=sample.flatMap { local($0.point) }
        guard target != nil || dragging else { _=gesture.update(ratio:.nan,pointing:false,target:nil,time:ProcessInfo.processInfo.systemUptime);return false }
        if let sample,sample.openPalm,let palm=sample.palmWorld,let frame=view.session.currentFrame {
            let camera=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
            if let factor=palmScale.update(target:"desktop",depth:Double(simd_distance(camera,palm)),time:sample.time) {
                root.simdScale=SIMD3(repeating:min(2,max(0.25,root.simdScale.x*factor)));onChange?()
            }
        } else { palmScale=SpatialPalmScale() }
        for event in gesture.update(ratio:sample?.ratio ?? .nan,pointing:sample?.pointing == true,target:target != nil ? "desktop" : nil,time:sample?.time ?? ProcessInfo.processInfo.systemUptime) {
            switch event {
            case .press:
                if let sample {
                    dragDepth=view.projectPoint(root.worldPosition).z
                    let p=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),dragDepth))
                    offset=root.simdWorldPosition-SIMD3(p.x,p.y,p.z);dragging=true
                }
            case .drag:
                if let sample {
                    let p=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),dragDepth))
                    root.simdWorldPosition=SIMD3(p.x,p.y,p.z)+offset
                }
            case .release,.cancel: if dragging { finishDrag() }
            case .click:
                if let point=target { input(["action":"click","x":point.x,"y":point.y]) }
            }
        }
        return true
    }

    private func finishDrag() {
        guard let root else { return };dragging=false
        if let anchor { view.session.remove(anchor:anchor) }
        var transform=root.simdWorldTransform
        for c in 0..<3 { let v=simd_normalize(SIMD3(transform[c].x,transform[c].y,transform[c].z));transform[c]=SIMD4(v,0) }
        let anchor=ARAnchor(name:"JarvisDesktop",transform:transform);self.anchor=anchor;view.session.add(anchor:anchor);onChange?()
    }

    func close(recordChange: Bool = true) {
        visible=false;setTracking(false)
        if let anchor { view.session.remove(anchor:anchor) }
        root?.removeFromParentNode();root=nil;anchor=nil;screen=nil;sequence=0
        if recordChange { onChange?() }
    }
}

struct SpatialDesktopControls: View {
    @ObservedObject var desktop: SpatialDesktop
    @State private var text=""
    @FocusState private var typing: Bool
    var body: some View {
        if desktop.visible {
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Text(desktop.status).font(.caption).lineLimit(2)
                    Spacer()
                    Button("Fechar PC") { desktop.close() }.font(.caption)
                }
                HStack {
                    TextField("Texto para o PC",text:$text).textFieldStyle(.roundedBorder).focused($typing)
                    Button("Digitar") {
                        desktop.input(["action":"text","text":String(text.prefix(500))]);text="";typing=false
                    }.disabled(text.isEmpty)
                    Menu("Teclas") {
                        ForEach(["enter","backspace","tab","escape","left","right","up","down"],id:\.self) { key in
                            Button(key) { desktop.input(["action":"key","key":key]) }
                        }
                        Button("Rolar para cima") { desktop.input(["action":"scroll","delta":2]) }
                        Button("Rolar para baixo") { desktop.input(["action":"scroll","delta":-2]) }
                    }
                }.font(.caption)
            }.padding(10).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:12))
                .onChange(of:typing) { _,value in desktop.inputBlocked=value }
                .onDisappear { desktop.inputBlocked=false }
        }
    }
}
