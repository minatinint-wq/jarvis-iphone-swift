import SwiftUI
import ARKit
import SceneKit
import AVFoundation

enum SpatialTheme: String, CaseIterable {
    case forest, enchanted, studio
    var title: String { switch self { case .forest: return "Bosque"; case .enchanted: return "Bosque noturno"; case .studio: return "Estúdio" } }
    var symbol: String { switch self { case .forest: return "leaf"; case .enchanted: return "moon.stars"; case .studio: return "hifispeaker" } }
}

/// Static geometry is from licensed finished models. Animation and interaction
/// are native and local; neither generation credits nor a web viewer are required.
@MainActor enum SpatialAssets {
    private static var cache: [String:SCNGeometry]=[:]
    static func load(_ id: String) throws -> SCNNode {
        if let geometry=cache[id] { return SCNNode(geometry:geometry) }
        guard let url=Bundle.main.url(forResource:"Spatial_"+id,withExtension:"mesh"),
              let manifest=Bundle.main.url(forResource:"SPATIAL_ASSETS",withExtension:"json") else { throw CocoaError(.fileNoSuchFile) }
        let data=try Data(contentsOf:url)
        guard data.count>=12, String(data:data.prefix(4),encoding:.ascii)=="JSP1" else { throw CocoaError(.fileReadCorruptFile) }
        let count=Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:UInt32.self) })
        let faces=Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:8,as:UInt32.self) })
        guard count>0, count<100000, faces>0, faces<100000, data.count==12+count*32+faces*12 else { throw CocoaError(.fileReadCorruptFile) }
        let buffer=data.subdata(in:12..<(12+count*32)), indices=data.suffix(faces*12)
        let sources=[SCNGeometrySource(data:buffer,semantic:.vertex,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:32),
                     SCNGeometrySource(data:buffer,semantic:.normal,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:12,dataStride:32),
                     SCNGeometrySource(data:buffer,semantic:.texcoord,vectorCount:count,usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:24,dataStride:32)]
        let geometry=SCNGeometry(sources:sources,elements:[SCNGeometryElement(data:indices,primitiveType:.triangles,primitiveCount:faces,bytesPerIndex:4)])
        let all=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [[String:Any]]
        guard let spec=all?.first(where:{ $0["id"] as? String == id }) else { throw CocoaError(.fileReadCorruptFile) }
        let mat=SCNMaterial(); mat.lightingModel = .physicallyBased; mat.isDoubleSided=spec["doubleSided"] as? Bool ?? false
        mat.metalness.contents=spec["metalness"] as? Double ?? 0
        mat.roughness.contents=spec["roughness"] as? Double ?? 1
        for (property,key) in [(mat.diffuse,"Color"),(mat.normal,"NormalGL"),(mat.roughness,"Roughness"),(mat.emission,"Emission")] {
            if let file=spec[key] as? String, let path=Bundle.main.path(forResource:file,ofType:nil), let bytes=try? Data(contentsOf:URL(fileURLWithPath:path)), let image=UIImage(data:bytes) {
                property.contents=image; property.mipFilter = .linear; property.minificationFilter = .linear; property.magnificationFilter = .linear; property.maxAnisotropy=4
            }
        }
        if (spec["metalness"] as? Double ?? 0)>0, let file=spec["Metalness"] as? String,
           let path=Bundle.main.path(forResource:file,ofType:nil) { mat.metalness.contents=UIImage(contentsOfFile:path) }
        if spec["alphaMode"] as? String == "MASK" {
            mat.shaderModifiers=[.surface:"if (_surface.diffuse.a < 0.5) { discard_fragment(); }"]
            mat.transparencyMode = .aOne
        }
        mat.normal.intensity=0.7; geometry.materials=[mat]; cache[id]=geometry
        return SCNNode(geometry:geometry)
    }
    static func clear() { cache.removeAll() }
    static func composition(_ theme: SpatialTheme) throws -> SCNNode {
        let root=SCNNode()
        func add(_ id: String, size: Float, x: Float, z: Float) throws -> SCNNode {
            let node=try load(id); node.name=id; node.scale=SCNVector3(size,size,size); node.position=SCNVector3(x,0.005,z)
            root.addChildNode(node); return node
        }
        switch theme {
        case .forest,.enchanted:
            _=try add("mossrock",size:0.45,x:-0.12,z:0.02)
            let fern=try add("fern",size:0.55,x:0.15,z:-0.10)
            fern.runAction(.repeatForever(.sequence([.rotateBy(x:0,y:0,z:0.025,duration:2.7),.rotateBy(x:0,y:0,z:-0.025,duration:2.7)])),forKey:"wind")
            if theme == .enchanted {
                let motes=SCNNode(); motes.name="motes"; root.addChildNode(motes)
                for i in 0..<16 {
                    let dot=SCNNode(geometry:SCNSphere(radius:0.003))
                    let a=Double(i)*2.39996
                    dot.position=SCNVector3(Float(cos(a))*0.27,0.15+Float(i%4)*0.06,Float(sin(a))*0.27)
                    dot.geometry?.firstMaterial?.lightingModel = .constant
                    dot.geometry?.firstMaterial?.diffuse.contents=UIColor(red:1,green:0.64,blue:0.12,alpha:1)
                    dot.runAction(.repeatForever(.sequence([.moveBy(x:0.02,y:0.03,z:0,duration:2+Double(i%3)),.moveBy(x:-0.02,y:-0.03,z:0,duration:2+Double(i%3))])))
                    motes.addChildNode(dot)
                }
                motes.runAction(.repeatForever(.rotateBy(x:0,y:.pi*2,z:0,duration:35)))
            }
        case .studio:
            _=try add("radio",size:0.40,x:0,z:0)
            let bars=SCNNode(); bars.name="equalizer"; bars.isHidden=true
            for i in 0..<12 {
                let bar=SCNNode(geometry:SCNCapsule(capRadius:0.004,height:0.055))
                bar.position=SCNVector3(Float(i-6)*0.018,0.06,0.24)
                bar.geometry?.firstMaterial?.lightingModel = .constant; bar.geometry?.firstMaterial?.diffuse.contents=UIColor.cyan
                bar.runAction(.repeatForever(.sequence([.scale(to:0.45,duration:0.18+Double(i%3)*0.08),.scale(to:1,duration:0.25)])))
                bars.addChildNode(bar)
            }
            root.addChildNode(bars)
        }
        return root
    }
}

@MainActor final class SpatialWorld: NSObject, ObservableObject {
    @Published var theme=SpatialTheme.forest
    @Published var active=false
    @Published var placing=false
    @Published var status="Escolha um cenário e toque em uma área livre do piso ou de uma mesa."
    @Published var objectCount=0
    @Published var hasSelection=false
    private let view: ARSCNView
    private var planes: [UUID:ARPlaneAnchor]=[:]
    private var objects: [UUID:SCNNode]=[:]
    private var supports: [UUID:UUID]=[:]
    private var anchors: [UUID:ARAnchor]=[:]
    private var selected: UUID?
    private var visibility=false
    private var player: AVAudioPlayer?
    private var playingID: UUID?
    private var initialScale: Float=1
    private var initialAngle: Float=0
    private var thermalPaused=false
    private var handGesture=SpatialGesture()
    private var handDragging:UUID?
    init(view: ARSCNView) { self.view=view; super.init() }
    func attach() {
        view.addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:))))
        view.addGestureRecognizer(UIRotationGestureRecognizer(target:self,action:#selector(rotate(_:))))
    }
    func setTheme(_ value: SpatialTheme) {
        active=true; theme=value
        if let selected, let root=objects[selected] {
            do {
                let replacement=try SpatialAssets.composition(value)
                player?.stop();playingID=nil
                root.childNodes.filter { $0.name != "selection" }.forEach { $0.removeFromParentNode() }
                root.addChildNode(replacement)
                status="\(value.title) no mesmo lugar. Toque para interagir; arraste para mover."
            } catch { status="Não consegui carregar o modelo incluído no app." }
        } else { placing=true; status="\(value.title): toque numa área livre e mapeada do piso ou mesa." }
    }
    func addAnother() { selected=nil; hasSelection=false; placing=true; active=true; status="Toque em outra área livre. Máximo: 6 conjuntos." }
    func tap(_ point: CGPoint, tracking: Bool) {
        guard active,tracking else { status="Espere o rastreamento estabilizar."; return }
        if !placing, let id=hit(point) {
            if selected==id { interact() } else { selected=id;hasSelection=true;markSelection();status="Selecionado. Toque novamente para interagir." }
            return
        }
        guard placing else { status="Toque em Adicionar para colocar outro conjunto."; return }
        guard objects.count<6 else { status="Limite de seis conjuntos para manter o desempenho."; return }
        guard let placement=placement(point,radius:0.48,ignoring:nil) else { return }
        do {
            let content=try SpatialAssets.composition(theme), root=SCNNode()
            let anchor=ARAnchor(name:"JarvisSpatialObject",transform:placement.0)
            root.simdTransform=anchor.transform;root.addChildNode(content);root.isHidden = !visibility
            view.scene.rootNode.addChildNode(root);view.session.add(anchor:anchor)
            objects[anchor.identifier]=root;anchors[anchor.identifier]=anchor;supports[anchor.identifier]=placement.1
            selected=anchor.identifier;objectCount=objects.count;hasSelection=true;placing=false;markSelection()
            status="\(theme.title) fixado. Arraste, gire com dois dedos ou use pinça. Toque para interagir."
        } catch { status="Falha ao abrir o modelo local: \(error.localizedDescription)" }
    }
    private func hit(_ point: CGPoint) -> UUID? {
        for result in view.hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue]) {
            var node: SCNNode?=result.node
            while let current=node {
                if let id=objects.first(where:{$0.value===current})?.key { return id };node=current.parent
            }
        }
        return nil
    }
    func hand(_ sample:SpatialHandSample?) {
        guard active,visibility,!placing else { handGesture.reset();return }
        let id=sample.flatMap { hit($0.point) }
        for event in handGesture.update(point:sample?.point,ratio:sample?.ratio ?? 1,target:id?.uuidString,push:nil,time:sample?.time ?? ProcessInfo.processInfo.systemUptime) {
            switch event {
            case .press(let key):selected=UUID(uuidString:key);hasSelection=selected != nil;markSelection()
            case .drag(let key):
                guard let id=UUID(uuidString:key),let node=objects[id],let sample,
                      let location=placement(sample.point,radius:0.48*node.simdScale.x,ignoring:id) else { continue }
                handDragging=id;node.simdPosition=SIMD3(location.0.columns.3.x,location.0.columns.3.y,location.0.columns.3.z);supports[id]=location.1
            case .release(_,let click):
                if let id=handDragging { reanchor(id);handDragging=nil } else if click { interact() }
            case .cancel:if let id=handDragging { reanchor(id);handDragging=nil }
            case .poke:break
            }
        }
    }
    /// Whole footprint must fit measured support. No placement on an estimated
    /// infinite plane, through walls, in doorways, or on an unmapped passage.
    private func placement(_ point: CGPoint, radius: Float, ignoring: UUID?) -> (simd_float4x4,UUID)? {
        guard let query=view.raycastQuery(from:point,allowing:.existingPlaneGeometry,alignment:.horizontal),
              let result=view.session.raycast(query).first, let plane=result.anchor as? ARPlaneAnchor,
              plane.classification == .floor || plane.classification == .table else {
            status="Mostre mais do piso ou da mesa. Não coloco objetos em área desconhecida.";return nil
        }
        let p=result.worldTransform.columns.3
        guard fits(p,radius:radius,on:plane,ignoring:ignoring) else {
            status="Muito perto de uma borda, parede, porta ou outro objeto. Escolha uma área livre.";return nil
        }
        var transform=matrix_identity_float4x4; transform.columns.3=p
        return (transform,plane.identifier)
    }
    private func fits(_ p: SIMD4<Float>,radius: Float,on plane: ARPlaneAnchor,ignoring: UUID?) -> Bool {
        let local=simd_inverse(plane.transform)*p
        let polygon=plane.geometry.boundaryVertices.map { SIMD2<Float>($0.x,$0.z) }
        for i in 0..<16 {
            let angle=Float(i)*2*Float.pi/16
            guard MeasuredWall.contains(SIMD2<Float>(local.x+cos(angle)*radius,local.z+sin(angle)*radius),polygon:polygon) else { return false }
        }
        for other in planes.values where other.alignment == .vertical {
            let q=simd_inverse(other.transform)*p
            if abs(q.y)<radius+0.10 && abs(q.x-other.center.x)<other.extent.x/2+radius && abs(q.z-other.center.z)<other.extent.z/2+0.55 { return false }
        }
        for (id,node) in objects where id != ignoring {
            let other=node.simdWorldPosition
            if simd_distance(SIMD2<Float>(p.x,p.z),SIMD2<Float>(other.x,other.z))<radius+0.48*node.simdScale.x { return false }
        }
        return true
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard active,visibility,!placing else { return }
        if gesture.state == .began { selected=hit(gesture.location(in:view));hasSelection=selected != nil;markSelection() }
        guard let id=selected, let node=objects[id], let result=placement(gesture.location(in:view),radius:0.48*node.simdScale.x,ignoring:id) else { return }
        node.simdPosition=SIMD3<Float>(result.0.columns.3.x,result.0.columns.3.y,result.0.columns.3.z);supports[id]=result.1
        if gesture.state == .ended || gesture.state == .cancelled { reanchor(id) }
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard active,visibility, let id=selected,let node=objects[id],let support=supports[id],let plane=planes[support] else { return }
        if gesture.state == .began { initialScale=node.simdScale.x }
        let scale=min(1.5,max(0.5,initialScale*Float(gesture.scale)))
        guard fits(SIMD4<Float>(node.simdPosition,1),radius:0.48*scale,on:plane,ignoring:id) else { status="Esse tamanho ultrapassa a área livre.";return }
        node.simdScale=SIMD3<Float>(repeating:scale)
        if gesture.state == .ended { reanchor(id) }
    }
    @objc private func rotate(_ gesture: UIRotationGestureRecognizer) {
        guard active,visibility, let id=selected, let node=objects[id] else { return }
        if gesture.state == .began { initialAngle=node.eulerAngles.y }
        node.eulerAngles.y=initialAngle-Float(gesture.rotation)
        if gesture.state == .ended { reanchor(id) }
    }
    private func reanchor(_ id: UUID) {
        guard let root=objects.removeValue(forKey:id),let old=anchors.removeValue(forKey:id) else { return }
        let support=supports.removeValue(forKey:id)
        view.session.remove(anchor:old)
        let new=ARAnchor(name:"JarvisSpatialObject",transform:root.simdTransform)
        objects[new.identifier]=root;anchors[new.identifier]=new;supports[new.identifier]=support
        if playingID==id { playingID=new.identifier }
        selected=new.identifier;view.session.add(anchor:new)
    }
    func interact() {
        guard visibility, let id=selected,let root=objects[id] else { return }
        UIImpactFeedbackGenerator(style:.medium).impactOccurred()
        if root.childNode(withName:"radio",recursively:true) != nil {
            if playingID==id { player?.stop();playingID=nil;root.childNode(withName:"equalizer",recursively:true)?.isHidden=true;status="Rádio pausado." }
            else if let url=Bundle.main.url(forResource:"Spatial_demo",withExtension:"wav") {
                do {
                    for node in objects.values { node.childNode(withName:"equalizer",recursively:true)?.isHidden=true }
                    player?.stop();player=try AVAudioPlayer(contentsOf:url);player?.numberOfLoops = -1
                    guard player?.play()==true else { status="Áudio indisponível nesta sessão.";return }
                    playingID=id;root.childNode(withName:"equalizer",recursively:true)?.isHidden=false
                    status="Tocando demonstração local. Toque novamente para parar."
                } catch { status="Não consegui iniciar o áudio local." }
            }
        } else if let motes=root.childNode(withName:"motes",recursively:true) {
            motes.isHidden.toggle();status=motes.isHidden ? "Vaga-lumes apagados." : "Vaga-lumes acesos."
        } else if let fern=root.childNode(withName:"fern",recursively:true) {
            fern.isPaused.toggle();status=fern.isPaused ? "Vento pausado." : "Vento nas folhas."
        }
    }
    private func markSelection() {
        for (id,root) in objects {
            root.childNode(withName:"selection",recursively:false)?.removeFromParentNode()
            if id==selected {
                let ring=SCNNode(geometry:SCNTorus(ringRadius:0.46,pipeRadius:0.002));ring.name="selection";ring.position.y=0.003
                ring.geometry?.firstMaterial?.lightingModel = .constant;ring.geometry?.firstMaterial?.diffuse.contents=UIColor.cyan
                root.addChildNode(ring)
            }
        }
    }
    func removeSelected() {
        guard let id=selected else { return }
        if playingID==id { player?.stop();playingID=nil }
        objects.removeValue(forKey:id)?.removeFromParentNode();supports.removeValue(forKey:id)
        if let anchor=anchors.removeValue(forKey:id) { view.session.remove(anchor:anchor) }
        selected=nil;hasSelection=false;objectCount=objects.count;status="Conjunto removido."
    }
    func update(_ anchor: ARAnchor) {
        if let plane=anchor as? ARPlaneAnchor { planes[plane.identifier]=plane }
        if let root=objects[anchor.identifier] { root.simdTransform=anchor.transform }
    }
    func remove(_ anchor: ARAnchor) { planes.removeValue(forKey:anchor.identifier) }
    func setVisible(_ value: Bool) {
        if !value { if let id=handDragging { reanchor(id);handDragging=nil };handGesture.reset() }
        visibility=value;objects.values.forEach { $0.isHidden = !value }
        if !value { player?.pause() }
        else if playingID != nil { player?.play() }
    }
    func setThermal(_ thermal: ProcessInfo.ThermalState) {
        let paused=thermal == .serious || thermal == .critical
        guard paused != thermalPaused else { return }; thermalPaused=paused
        objects.values.forEach { $0.isPaused=paused }
    }
    func stop() {
        player?.stop();player=nil
        objects.values.forEach { $0.removeFromParentNode() };objects.removeAll();anchors.removeAll();planes.removeAll();SpatialAssets.clear()
    }
}

struct SpatialControls: View {
    @ObservedObject var world: SpatialWorld
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                ForEach(SpatialTheme.allCases,id:\.rawValue) { theme in
                    Button { world.setTheme(theme) } label: { Label(theme.title,systemImage:theme.symbol).font(.caption) }
                        .buttonStyle(.bordered).tint(world.theme == theme ? .cyan : .gray)
                }
            }
            Text(world.status).font(.caption).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("Adicionar",systemImage:"plus") { world.addAnother() }.disabled(world.objectCount>=6)
                Button("Interagir",systemImage:"hand.tap") { world.interact() }.disabled(!world.hasSelection)
                Button("Remover",systemImage:"trash") { world.removeSelected() }.disabled(!world.hasSelection)
            }.buttonStyle(.bordered).controlSize(.small)
            Text("Modelos incluídos · sem geração · toque, arraste e use dois dedos. Objetos duram nesta sessão.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
