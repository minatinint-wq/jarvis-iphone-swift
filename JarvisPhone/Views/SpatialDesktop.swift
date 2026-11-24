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
    var inputBlocked=false { didSet { if inputBlocked { gesture.reset();keyGesture.reset();headerGesture.reset();scroll=SpatialDesktopScroll();palmScale=SpatialPalmScale() } } }
    private let view: ARSCNView
    private var root: SCNNode?
    private var screen: SCNPlane?
    private var anchor: ARAnchor?
    private var sequence=0
    private var pending: UUID?
    private var sentAt=0.0
    private var queuedInput: [[String:Any]]=[]
    private var focusToken:String?
    private var autoFocusHandled:String?
    private var automaticKeyboard=false
    @Published private(set) var keyboardVisible=false
    private var shift=false,symbols=false
    private var keyGesture=SpatialGesture(dwellDuration:0.55)
    private var headerGesture=SpatialGesture()
    private var scroll=SpatialDesktopScroll()
    private var keyboardPoseSince:Double?
    private var keyboardPoseFired=false
    private var dwellOrigin:SIMD2<Float>?
    private var dwellID=0
    private enum ProjectedKey { case job([String:Any]),toggle,shift,symbols,close,recenter }
    private var projectedKeys:[String:ProjectedKey]=[:]
    private var loop: Task<Void,Never>?
    private var gesture=SpatialGesture()
    private var palmScale=SpatialPalmScale()
    private var palmCalibration=SpatialPalmCalibration()
    private var pinchZoom=SpatialPinchZoom()
    private func handDepth(_ sample:SpatialHandSample) -> Double? {
        guard let frame=view.session.currentFrame,let palm=sample.palmWorld else { return nil }
        let p=frame.camera.transform.columns.3
        return Double(simd_distance(SIMD3(p.x,p.y,p.z),palm))
    }
    private var dragging=false
    var isDragging: Bool { dragging }
    func resize(_ factor:Float) {
        guard visible,tracking,let root,factor.isFinite,factor>0 else { return }
        root.simdScale=SIMD3(repeating:min(2,max(0.25,root.simdScale.x*factor)));onChange?()
    }
    private var offset=SIMD3<Float>.zero
    private var dragDepth:Float=0
    private var tracking=false
    var progress: Double { max(gesture.progress,max(keyGesture.progress,headerGesture.progress)) }

    init(view: ARSCNView) { self.view=view }
    #if DEBUG
    func preview() {
        build(anchor:ARAnchor(name:"JarvisDesktop",transform:matrix_identity_float4x4),scale:0.7)
        visible=true;tracking=true;root?.isHidden=false;sequence=1
    }
    var previewPosition: SIMD3<Float>? { root?.simdWorldPosition }
    #endif

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
        self.anchor=anchor;root=node;screen=plane;view.scene.rootNode.addChildNode(node);renderControls()
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
    func contains(_ point: CGPoint) -> Bool { visible && tracking && (local(point) != nil || control(point) != nil) }
    var isFramed: Bool {
        guard visible,let root,let screen else { return false };return SpatialPanelGeometry.framed(root,in:view,size:CGSize(width:0.64,height:screen.height))
    }
    func recenter() {
        guard visible,tracking,!dragging,let root,let frame=view.session.currentFrame else { return }
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix=frame.camera.viewMatrix(for:orientation),camera=simd_inverse(viewMatrix)
        guard let pose=SpatialPanelGeometry.upright(camera:camera,distance:0.65) else { return }
        let scale=SpatialPanelGeometry.fittedScale(transform:pose,view:viewMatrix,projection:frame.camera.projectionMatrix(for:orientation,viewportSize:view.bounds.size,zNear:0.01,zFar:20),viewport:view.bounds.size) ?? 0.5
        if let anchor { view.session.remove(anchor:anchor) }
        root.simdTransform=pose;root.simdScale=SIMD3(repeating:scale)
        let next=ARAnchor(name:"JarvisDesktop",transform:pose);anchor=next;view.session.add(anchor:next);onChange?()
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
                    if self.pending != nil,now-self.sentAt>7 { self.pending=nil;self.queuedInput=[];self.sequence=0;self.status="A ponte não atualizou a tela. Tentando reconectar…" }
                    if self.pending == nil { self.request(["action":"frame"]) }
                    try? await Task.sleep(for:.milliseconds(200))
                }
            }
        } else {
            loop?.cancel();loop=nil;gesture.reset();palmScale=SpatialPalmScale();pending=nil;queuedInput=[];scroll=SpatialDesktopScroll();keyGesture.reset();headerGesture.reset()
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
        guard data["ok"] as? Bool == true else { queuedInput=[];sequence=0;focusToken=nil;status=data["message"] as? String ?? "Desktop indisponível.";return }
        if let encoded=data["image"] as? String,encoded.count<350000,let bytes=Data(base64Encoded:encoded),let image=UIImage(data:bytes),
           let width=data["width"] as? Int,let height=data["height"] as? Int,width>0,height>0 {
            let newHeight=0.64*CGFloat(height)/CGFloat(width),changed=abs((screen?.height ?? 0)-newHeight)>0.005
            screen?.height=newHeight;screen?.firstMaterial?.diffuse.contents=image
            if changed { renderControls() }
            sequence=data["sequence"] as? Int ?? 0;status="PC ao vivo · dois dedos rolam · três dedos abrem o teclado"
        }
        if let token=focusToken,token != autoFocusHandled,data["focusToken"] as? String == token,data["focusKnown"] as? Bool == true {
            autoFocusHandled=token
            if data["focusEditable"] as? Bool == true,!keyboardVisible { keyboardVisible=true;automaticKeyboard=true;renderControls() }
            else if data["focusEditable"] as? Bool == false,automaticKeyboard { keyboardVisible=false;automaticKeyboard=false;renderControls() }
        }
        if !queuedInput.isEmpty { request(queuedInput.removeFirst()) }
    }

    func input(_ job: [String:Any]) {
        guard sequence>0,visible,tracking else { return }
        var packet=job
        if packet["action"] as? String == "click" { let token=UUID().uuidString;focusToken=token;packet["focusToken"]=token }
        if pending != nil {
            if packet["action"] as? String == "scroll",let amount=packet["delta"] as? Int,
               let last=queuedInput.last,last["action"] as? String == "scroll",let previous=last["delta"] as? Int,abs(previous+amount)<=5 {
                queuedInput[queuedInput.count-1]["delta"]=previous+amount
            } else if queuedInput.count<32 { queuedInput.append(packet) }
            else { status="Aguardando o PC terminar os comandos." }
        } else { request(packet) }
    }

    private func planePoint(_ point:CGPoint,z:Float=0)->SIMD2<Float>? {
        guard let root else { return nil }
        let a=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),0)),b=view.unprojectPoint(SCNVector3(Float(point.x),Float(point.y),1))
        let inverse=simd_inverse(root.simdWorldTransform),o=inverse*SIMD4(a.x,a.y,a.z,1),d=inverse*SIMD4(b.x-a.x,b.y-a.y,b.z-a.z,0)
        guard d.z < -0.0001 else { return nil };let t=(z-o.z)/d.z
        let p=o+d*t;guard t>=0,p.x.isFinite,p.y.isFinite else { return nil };return SIMD2(p.x,p.y)
    }
    private func local(_ point:CGPoint)->SIMD2<Float>? {
        guard let p=planePoint(point),let screen,abs(p.x)<=0.32,abs(p.y)<=Float(screen.height/2) else { return nil }
        return SIMD2(p.x/0.64+0.5,0.5-p.y/Float(screen.height))
    }
    private func control(_ point:CGPoint)->SCNNode? {
        guard let p=planePoint(point,z:0.006),let root else { return nil }
        return root.childNodes.first { node in
            guard node.name?.hasPrefix("desktop-ui:")==true,let plane=node.geometry as? SCNPlane else { return false }
            return abs(p.x-node.position.x)<=Float(plane.width)/2 && abs(p.y-node.position.y)<=Float(plane.height)/2
        }
    }
    func tap(_ point:CGPoint)->Bool {
        guard visible,tracking else { return false }
        if let node=control(point) { if let key=node.name.flatMap({projectedKeys[$0]}) { activate(key) };return true }
        guard let p=local(point) else { return false };input(["action":"click","x":Double(p.x),"y":Double(p.y)]);return true
    }
    func showKeyboard(_ value:Bool) { keyboardVisible=value;automaticKeyboard=false;autoFocusHandled=focusToken;keyGesture.reset();renderControls() }
    func toggleKeyboard() { showKeyboard(!keyboardVisible) }
    private func activate(_ key:ProjectedKey) {
        switch key {
        case .toggle:toggleKeyboard()
        case .close:keyboardVisible=false;automaticKeyboard=false;autoFocusHandled=focusToken;renderControls()
        case .shift:shift.toggle();renderControls()
        case .symbols:symbols.toggle();renderControls()
        case .recenter:recenter()
        case .job(var job):
            if let text=job["text"] as? String,shift { job["text"]=text.uppercased() }
            input(job)
        }
    }
    private func renderControls() {
        guard let root,let screen else { return }
        root.childNodes.filter { $0.name?.hasPrefix("desktop-ui:")==true }.forEach { $0.removeFromParentNode() };projectedKeys=[:]
        let color=UIColor(red:0.02,green:0.10,blue:0.14,alpha:0.98)
        func key(_ id:String,_ title:String,_ x:Float,_ y:Float,_ w:CGFloat,_ h:CGFloat,_ action:ProjectedKey?) {
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let size=CGSize(width:w*1800,height:h*1800)
            let image=UIGraphicsImageRenderer(size:size,format:format).image { _ in
                color.setFill();UIBezierPath(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:12).fill()
                let font=UIFont.systemFont(ofSize:title.count>10 ? 22 : title.count>3 ? 27 : 40,weight:.medium)
                let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.cyan]
                let measured=(title as NSString).size(withAttributes:attrs)
                (title as NSString).draw(at:CGPoint(x:max(3,(size.width-measured.width)/2),y:(size.height-measured.height)/2),withAttributes:attrs)
            }
            let plane=SCNPlane(width:w,height:h);plane.cornerRadius=0.005
            let material=SCNMaterial();material.diffuse.contents=image;material.lightingModel = .constant;material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false;plane.materials=[material]
            let node=SCNNode(geometry:plane);node.name="desktop-ui:"+id;node.categoryBitMask=8;node.renderingOrder=112;node.position=SCNVector3(x,y,0.006);root.addChildNode(node)
            if let action { projectedKeys[node.name!]=action }
        }
        let top=Float(screen.height/2)+0.032
        key("help","☝ 2s clicar · ✌ rolar · 3 dedos: teclado",-0.065,top,0.50,0.05,nil)
        key("keyboard","⌨",0.235,top,0.075,0.05,.toggle)
        key("recenter","◎",0.302,top,0.05,0.05,.recenter)
        guard keyboardVisible else { return }
        let start = -Float(screen.height/2)-0.055
        key("keyboard-title",symbols ? "TECLADO · 123" : "TECLADO · ABC",-0.08,start,0.44,0.045,nil)
        key("shift",shift ? "⇧ ON" : "⇧",0.185,start,0.08,0.045,.shift)
        key("close","×",0.275,start,0.08,0.045,.close)
        let rows=symbols ? ["1234567890","@#$%&*()-=","!?.,:;/_+ç"] : ["qwertyuiop","asdfghjklç","zxcvbnm,."]
        for (row,text) in rows.enumerated() {
            let chars=Array(text),width:Float=0.060
            for (column,char) in chars.enumerated() {
                let value=String(char),x=(Float(column)-Float(chars.count-1)/2)*width
                key("text-"+value,shift ? value.uppercased() : value,x,start-Float(row+1)*0.057,0.055,0.05,.job(["action":"text","text":value]))
            }
        }
        let bottom=start-0.235
        key("symbols",symbols ? "ABC" : "123",-0.265,bottom,0.10,0.055,.symbols)
        key("tab","Tab",-0.16,bottom,0.09,0.055,.job(["action":"key","key":"tab"]))
        key("space","Espaço",0,bottom,0.21,0.055,.job(["action":"text","text":" "]))
        key("backspace","⌫",0.16,bottom,0.09,0.055,.job(["action":"key","key":"backspace"]))
        key("enter","↵",0.265,bottom,0.10,0.055,.job(["action":"key","key":"enter"]))
    }
    @discardableResult func hand(_ sample:SpatialHandSample?)->Bool {
        guard visible,tracking,!inputBlocked,let root else { return false }
        let time=sample?.time ?? ProcessInfo.processInfo.systemUptime
        let point=sample?.point,button=point.flatMap(control),target=point.flatMap(local)
        if sample?.keyboardPose==true,(target != nil || button != nil) {
            if dragging { finishDrag() }
            gesture.reset();keyGesture.reset();headerGesture.reset();scroll=SpatialDesktopScroll();dwellOrigin=nil
            if keyboardPoseSince==nil { keyboardPoseSince=time }
            if !keyboardPoseFired,time-(keyboardPoseSince ?? time)>0.65 { toggleKeyboard();keyboardPoseFired=true }
            return true
        }
        keyboardPoseSince=nil;keyboardPoseFired=false
        if let button {
            if dragging { finishDrag() }
            gesture.reset();scroll=SpatialDesktopScroll();dwellOrigin=nil
            let id=button.name.flatMap { projectedKeys[$0] == nil ? nil : $0 }
            let header=id == "desktop-ui:keyboard" || id == "desktop-ui:recenter"
            let events:[SpatialGesture.Event]
            if header { keyGesture.reset();events=headerGesture.update(ratio:sample?.ratio ?? .nan,pointing:sample?.pointing == true,target:id,time:time) }
            else { headerGesture.reset();events=keyGesture.update(ratio:sample?.ratio ?? .nan,pointing:sample?.pointing == true,target:id,time:time) }
            for event in events {
                if case .click(let id)=event,let action=projectedKeys[id] { UIImpactFeedbackGenerator(style:.light).impactOccurred();activate(action) }
            }
            return true
        }
        keyGesture.reset();headerGesture.reset()
        if sample?.menuPose==true,let target {
            if dragging { finishDrag() }
            gesture.reset();dwellOrigin=nil
            if let delta=scroll.update(point:CGPoint(x:CGFloat(target.x),y:CGFloat(target.y)),time:time) {
                input(["action":"scroll","delta":delta,"x":Double(target.x),"y":Double(target.y)])
            }
            status="Rolando com dois dedos · solte a mão para parar";return true
        }
        scroll=SpatialDesktopScroll()
        guard target != nil || dragging else { _=gesture.update(ratio:.nan,pointing:false,target:nil,time:time);dwellOrigin=nil;return false }
        palmScale=SpatialPalmScale();palmCalibration=SpatialPalmCalibration()
        if sample?.pointing==true,let target {
            if dwellOrigin==nil || simd_distance(dwellOrigin!,target)>0.025 { dwellID+=1;dwellOrigin=target }
        } else { dwellOrigin=nil }
        let id=target == nil ? nil : sample?.pointing==true ? "desktop-click-\(dwellID)" : "desktop-window"
        for event in gesture.update(ratio:sample?.ratio ?? .nan,pointing:sample?.pointing == true,target:id,time:time) {
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
            case .release,.cancel:if dragging { finishDrag() }
            case .click:if let point=target { input(["action":"click","x":Double(point.x),"y":Double(point.y)]) }
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
        root?.removeFromParentNode();root=nil;anchor=nil;screen=nil;sequence=0;keyboardVisible=false;focusToken=nil;autoFocusHandled=nil
        if recordChange { onChange?() }
    }
}

struct SpatialDesktopControls: View {
    @ObservedObject var desktop:SpatialDesktop
    var body:some View {
        if desktop.visible {
            HStack {
                Text(desktop.status).font(.caption).lineLimit(1)
                Spacer()
                Button(desktop.keyboardVisible ? "Recolher teclado" : "Teclado no espaço") { desktop.toggleKeyboard() }
                Button("Fechar PC") { desktop.close() }
            }.font(.caption).padding(8).background(.black.opacity(0.65),in:Capsule())
        }
    }
}
