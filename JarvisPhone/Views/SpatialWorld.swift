import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import Darwin

enum SpatialDemo: String, CaseIterable {
    case human = "demo_human", box = "demo_box", chair = "demo_chair", table = "demo_table", panel = "demo_panel"
    var title: String {
        switch self { case .human:return "Personagem · 1,70 m";case .box:return "Caixa · 30 cm";case .chair:return "Cadeira · 90 cm";case .table:return "Mesa · 75 cm";case .panel:return "Painel · 60 cm" }
    }
    var radius: Float {
        switch self { case .human:return 0.36;case .box:return 0.22;case .chair:return 0.33;case .table:return 0.66;case .panel:return 0.31 }
    }
    @MainActor func make() throws -> SCNNode {
        let node = try SpatialAssets.load(rawValue);node.name="catalogObject";return node
    }
}

enum SpatialTheme: String, CaseIterable {
    case forest, enchanted, studio, garage, lounge, aquarium
    var title: String { switch self { case .forest: return "Bosque"; case .enchanted: return "Bosque noturno"; case .studio: return "Estúdio"; case .garage:return "Garagem"; case .lounge:return "Sala interativa"; case .aquarium:return "Jardim aquático" } }
    var symbol: String { switch self { case .forest: return "leaf"; case .enchanted: return "moon.stars"; case .studio: return "hifispeaker"; case .garage:return "car"; case .lounge:return "sofa"; case .aquarium:return "fish" } }
}

/// Static geometry is from licensed finished models. Animation and interaction
/// are native and local; neither generation credits nor a web viewer are required.
@MainActor enum SpatialAssets {
    struct Entry:Identifiable { let id:String;let title:String }
    static var catalog:[Entry] {
        guard let url=Bundle.main.url(forResource:"SPATIAL_ASSETS",withExtension:"json"),let bytes=try? Data(contentsOf:url),let entries=try? JSONSerialization.jsonObject(with:bytes) as? [[String:Any]] else { return [] }
        return entries.compactMap { spec in guard let id=spec["id"] as? String,let title=spec["title"] as? String else { return nil };return Entry(id:id,title:title) }
    }
    private static var cache: [String:SCNNode]=[:]
    static func load(_ id: String) throws -> SCNNode {
        if let node=cache[id] { return node.clone() }
        guard let manifest=Bundle.main.url(forResource:"SPATIAL_ASSETS",withExtension:"json"),
              let all=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [[String:Any]],
              let spec=all.first(where:{$0["id"] as? String == id}) else { throw CocoaError(.fileNoSuchFile) }
        let node:SCNNode
        if let parts=spec["parts"] as? [[String:Any]] {
            node=SCNNode()
            for part in parts { node.addChildNode(try partNode(part,mesh:part["mesh"] as? String ?? "")) }
        } else { node=try partNode(spec,mesh:"Spatial_"+id+".mesh") }
        if cache.count>=3 { cache.removeAll() }
        cache[id]=node;return node.clone()
    }
    private static func partNode(_ spec:[String:Any],mesh:String) throws -> SCNNode {
        guard let url=Bundle.main.url(forResource:mesh,withExtension:nil) else { throw CocoaError(.fileNoSuchFile) }
        let data=try Data(contentsOf:url)
        guard data.count>=12, String(data:data.prefix(4),encoding:.ascii)=="JSP1" else { throw CocoaError(.fileReadCorruptFile) }
        let count=Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:UInt32.self) })
        let faces=Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:8,as:UInt32.self) })
        guard count>0, count<300000, faces>0, faces<300000, data.count==12+count*32+faces*12 else { throw CocoaError(.fileReadCorruptFile) }
        let buffer=data.subdata(in:12..<(12+count*32)), indices=data.suffix(faces*12)
        let sources=[SCNGeometrySource(data:buffer,semantic:.vertex,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:32),
                     SCNGeometrySource(data:buffer,semantic:.normal,vectorCount:count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:12,dataStride:32),
                     SCNGeometrySource(data:buffer,semantic:.texcoord,vectorCount:count,usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:24,dataStride:32)]
        let geometry=SCNGeometry(sources:sources,elements:[SCNGeometryElement(data:indices,primitiveType:.triangles,primitiveCount:faces,bytesPerIndex:4)])
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
        if let c=spec["baseColor"] as? [Double],c.count==4 {
            let color=UIColor(red:c[0],green:c[1],blue:c[2],alpha:c[3])
            if spec["Color"] != nil { mat.multiply.contents=color } else { mat.diffuse.contents=color }
        }
        if let c=spec["emissionFactor"] as? [Double],c.count==3,spec["Emission"] == nil { mat.emission.contents=UIColor(red:c[0],green:c[1],blue:c[2],alpha:1) }
        if spec["glass"] as? Bool == true { mat.transparency=0.28;mat.isDoubleSided=true;mat.writesToDepthBuffer=false }
        mat.normal.intensity=0.7; geometry.materials=[mat]
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
        case .garage:
            let car=try add("toycar",size:0.30,x:0,z:0);car.name="movingCar"
            _=try add("trafficcone",size:0.10,x:0.25,z:0.12)
            _=try add("scifihelmet",size:0.14,x:-0.23,z:-0.12)
        case .lounge:
            _=try add("glamvelvetsofa",size:0.42,x:0,z:-0.10)
            _=try add("specularsilkpouf",size:0.16,x:-0.20,z:0.18)
            _=try add("anisotropybarnlamp",size:0.24,x:0.24,z:0.02)
            let glow=SCNNode();glow.name="roomLight";glow.position=SCNVector3(0.22,0.28,0.10)
            glow.light=SCNLight();glow.light?.type = .omni;glow.light?.color=UIColor.orange;glow.light?.intensity=120;glow.light?.attenuationEndDistance=0.8;root.addChildNode(glow)
        case .aquarium:
            _=try add("mossrock",size:0.22,x:-0.15,z:0)
            _=try add("fern",size:0.32,x:0.16,z:-0.10)
            let orbit=SCNNode();orbit.name="fishOrbit";root.addChildNode(orbit)
            let fish=try load("barramundifish");fish.scale=SCNVector3(0.18,0.18,0.18);fish.position=SCNVector3(0.19,0.24,0);orbit.addChildNode(fish)
            orbit.runAction(.repeatForever(.rotateBy(x:0,y:.pi*2,z:0,duration:14)),forKey:"swim")
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
    @Published var selectedModel:String?
    var panelBlocking=false
    private var radii:[UUID:Float]=[:]
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
    var dwellProgress: Double { handGesture.progress }
    private var handGesture=SpatialGesture()
    private var handDragging:UUID?
    private var handOffset=SIMD3<Float>.zero
    private var palmScale=SpatialPalmScale()
    @Published var persistenceStatus = "Mapa ainda não salvo."
    @Published var roomName = "Ambiente 1"
    private var worldID = UUID()
    private var rooms = [SpatialRoom(id:UUID(),name:"Ambiente 1",origin:SpatialArchive.values(matrix_identity_float4x4))]
    private var records: [UUID:SpatialObjectRecord] = [:]
    private var restored: [UUID:SpatialObjectRecord] = [:]
    private var revision = 0
    private var saving = false
    private var lastSavedRevision = -1
    private var lastSaveAttempt: TimeInterval = -.infinity
    private var currentRoom: UUID?
    private var relocalizationBegan: TimeInterval?
    private var diagnostics: [[String:Any]] = []
    private var lastDiagnostic: TimeInterval = -.infinity
    var panelSnapshot: (() -> SpatialPanelRecord?)?
    var desktopSnapshot: (() -> SpatialDesktopRecord?)?
    var restoredPanel: SpatialPanelRecord?
    var restoredDesktop: SpatialDesktopRecord?
    private let storageQueue = DispatchQueue(label:"jarvis.spatial.persistence",qos:.utility)
    var recovering: Bool { !restored.isEmpty || restoredPanel != nil || restoredDesktop != nil }
    func markDirty() { revision+=1 }

    func loadMap() async throws -> ARWorldMap? {
        let archive = try await Task.detached(priority:.utility) { try SpatialArchive.load() }.value
        guard let archive else { return nil }
        let map = try NSKeyedUnarchiver.unarchivedObject(ofClass:ARWorldMap.self,from:archive.map)
        guard let map, archive.objects.allSatisfy({ record in map.anchors.contains { $0.identifier == record.anchor && $0.name == "JarvisObject:" + record.id.uuidString } }),
              archive.panel.map({ panel in map.anchors.contains { $0.identifier == panel.anchor && $0.name == "JarvisControlPanel" } }) ?? true,
              archive.desktop.map({ desktop in map.anchors.contains { $0.identifier == desktop.anchor && $0.name == "JarvisDesktop" } }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        worldID=archive.world;rooms=archive.rooms;currentRoom=rooms.first?.id;roomName=rooms.first?.name ?? "Ambiente 1"
        records=Dictionary(uniqueKeysWithValues:archive.objects.map { ($0.id,$0) });restored=records
        restoredPanel=archive.panel
        restoredDesktop=archive.desktop
        relocalizationBegan=ProcessInfo.processInfo.systemUptime
        revision=0;lastSavedRevision=0
        active = !records.isEmpty
        persistenceStatus="Relocalizando mapa salvo. Mostre o ambiente original; objetos aguardam suas âncoras."
        return map
    }

    func chooseRoom(_ name: String) {
        guard !recovering else { persistenceStatus="Espere a relocalização antes de identificar outro ambiente.";return }
        selected=nil;hasSelection=false;placing=false;markSelection()
        if let room=rooms.first(where: { $0.name == name }) { currentRoom=room.id;roomName=room.name;return }
        guard rooms.count<32,let camera=view.session.currentFrame?.camera.transform else { return }
        var origin=matrix_identity_float4x4;origin.columns.3=camera.columns.3
        let room=SpatialRoom(id:UUID(),name:name,origin:SpatialArchive.values(origin))
        rooms.append(room);currentRoom=room.id;roomName=name;revision+=1
    }

    func saveMap(force: Bool = true) {
        guard !saving,!recovering,handDragging == nil,let frame=view.session.currentFrame,
              case .normal=frame.camera.trackingState,frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else {
            if force { persistenceStatus="Para salvar, termine o gesto e mostre mais detalhes do ambiente até o mapa estabilizar." };return
        }
        guard force || revision != lastSavedRevision else { return }
        lastSaveAttempt=frame.timestamp;saving=true
        let savedRevision=revision, snapshot=Array(records.values), roomSnapshot=rooms, world=worldID, panel=panelSnapshot?(),desktop=desktopSnapshot?()
        view.session.getCurrentWorldMap { [self] map,error in
            Task { @MainActor in
                guard let map,error == nil,self.revision == savedRevision,
                      snapshot.allSatisfy({ record in map.anchors.contains { $0.identifier == record.anchor } }),
                      panel.map({ p in map.anchors.contains { $0.identifier == p.anchor } }) ?? true,
                      desktop.map({ p in map.anchors.contains { $0.identifier == p.anchor } }) ?? true else {
                    self.saving=false;self.persistenceStatus="Mapa não salvo. Aguarde estabilizar e tente novamente.";return
                }
                self.storageQueue.async {
                    do {
                        let bytes=try NSKeyedArchiver.archivedData(withRootObject:map,requiringSecureCoding:true)
                        let archive=SpatialArchive(world:world,rooms:roomSnapshot,objects:snapshot,panel:panel,desktop:desktop,map:bytes,saved:Date())
                        try archive.write()
                        Task { @MainActor in self.saving=false;self.lastSavedRevision=savedRevision;self.persistenceStatus="Salvo no iPhone: \(snapshot.count) objetos e \(roomSnapshot.count) ambientes." }
                    } catch {
                        Task { @MainActor in self.saving=false;self.persistenceStatus="Falha ao salvar: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    func persistenceTick(_ frame: ARFrame) {
        if case .limited(.relocalizing)=frame.camera.trackingState,relocalizationBegan == nil {
            relocalizationBegan=ProcessInfo.processInfo.systemUptime
        }
        if frame.timestamp-lastSaveAttempt>30 { saveMap(force:false);lastSaveAttempt=frame.timestamp }
    }

    func recordPerformance(fps: Int, frame: ARFrame) {
        guard frame.timestamp-lastDiagnostic>=5 else { return };lastDiagnostic=frame.timestamp
        var entry:[String:Any] = ["date":Date().timeIntervalSince1970,"fps":fps,"objects":objectCount,
                                 "thermal":ProcessInfo.processInfo.thermalState.rawValue,
                                 "mapping":frame.worldMappingStatus.rawValue,"battery":UIDevice.current.batteryLevel]
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) }
        }
        if result == KERN_SUCCESS { entry["residentMB"]=Double(info.resident_size)/1048576 }
        if let began=relocalizationBegan,!recovering,restoredPanel==nil,case .normal=frame.camera.trackingState {
            entry["relocalizationSeconds"]=ProcessInfo.processInfo.systemUptime-began
            entry["restoredAnchors"]=records.count
            var deltas:[[String:Any]]=[]
            for record in records.values {
                guard let room=rooms.first(where:{$0.id==record.room}),let origin=SpatialArchive.matrix(room.origin),
                      let local=SpatialArchive.matrix(record.localTransform),let anchor=anchors[record.id] else { continue }
                let expected=origin*local,actual=anchor.transform
                let a=SIMD3(expected.columns.3.x,expected.columns.3.y,expected.columns.3.z)
                let b=SIMD3(actual.columns.3.x,actual.columns.3.y,actual.columns.3.z)
                let angle=2*acos(min(1,abs(simd_dot(simd_quatf(expected).vector,simd_quatf(actual).vector))))
                deltas.append(["id":record.id.uuidString,"metersFromSavedTransform":simd_distance(a,b),"radiansFromSavedTransform":angle,"scale":record.scale])
            }
            entry["anchorDeltas"]=deltas;relocalizationBegan=nil
            persistenceStatus="Mapa relocalizado. \(objectCount) objetos recuperados. Confira a posição física."
        }
        diagnostics.append(entry)
        if diagnostics.count>300 { diagnostics.removeFirst(diagnostics.count-300) }
        guard let bytes=try? JSONSerialization.data(withJSONObject:diagnostics,options:[.sortedKeys]) else { return }
        let file=SpatialArchive.file.deletingLastPathComponent().appendingPathComponent("diagnostics.json")
        storageQueue.async {
            try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? bytes.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func remember(_ id: UUID, model: String? = nil) {
        guard let node=objects[id],let anchor=anchors[id],let room=rooms.first(where:{$0.id == (records[id]?.room ?? currentRoom ?? rooms[0].id)}),
              let origin=SpatialArchive.matrix(room.origin) else { return }
        records[id]=SpatialObjectRecord(id:id,model:model ?? records[id]?.model ?? "theme:"+theme.rawValue,room:room.id,anchor:anchor.identifier,
                                      localTransform:SpatialArchive.values(simd_inverse(origin)*anchor.transform),scale:node.simdScale.x,updated:Date())
        revision+=1
    }
    init(view: ARSCNView) { self.view=view; super.init() }
    func attach() {
        view.addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:))))
        view.addGestureRecognizer(UIRotationGestureRecognizer(target:self,action:#selector(rotate(_:))))
    }
    func setTheme(_ value: SpatialTheme) {
        guard !recovering else { status="Aguarde recuperar as âncoras do mapa salvo.";return }
        active=true; theme=value;selectedModel=nil
        if let selected, let root=objects[selected] {
            guard let support=supports[selected],let plane=planes[support],fits(SIMD4(root.simdPosition,1),radius:0.48*root.simdScale.x,on:plane,ignoring:selected) else { status="O cenário precisa de mais área livre. Use Adicionar.";return }
            do {
                let replacement=try SpatialAssets.composition(value)
                guard triangles(replacement)+objects.filter({$0.key != selected}).values.reduce(0,{$0+triangles($1)})<=350000 else { status="Remova outro objeto antes de trocar para esse cenário.";return }
                radii[selected]=0.48
                player?.stop();playingID=nil
                root.childNodes.filter { $0.name != "selection" }.forEach { $0.removeFromParentNode() }
                root.addChildNode(replacement)
                remember(selected,model:"theme:"+value.rawValue)
                status="\(value.title) no mesmo lugar. Toque para interagir; arraste para mover."
            } catch { status="Não consegui carregar o modelo incluído no app." }
        } else { placing=true; status="\(value.title): toque numa área livre e mapeada do piso ou mesa." }
    }
    func setModel(_ id:String) {
        guard !recovering,SpatialAssets.catalog.contains(where:{$0.id==id}) || SpatialDemo.allCases.contains(where:{$0.rawValue==id}) else { return }
        active=true;selectedModel=id;selected=nil;hasSelection=false;placing=true
        status=SpatialDemo(rawValue:id).map { "\($0.title): toque em uma área livre do piso." } ?? "\(SpatialAssets.catalog.first(where:{$0.id==id})?.title ?? id): toque no piso ou numa mesa. Tamanho inicial: até 30 cm."
    }
    private func content() throws -> SCNNode {
        guard let selectedModel else { return try SpatialAssets.composition(theme) }
        if let demo=SpatialDemo(rawValue:selectedModel) { return try demo.make() }
        let holder=SCNNode();holder.name="catalogObject"
        let model=try SpatialAssets.load(selectedModel);model.scale=SCNVector3(0.30,0.30,0.30);holder.addChildNode(model)
        return holder
    }
    private func radius(_ id:UUID)->Float { radii[id] ?? 0.48 }
    private func triangles(_ node:SCNNode)->Int {
        (node.geometry?.elements.reduce(0,{$0+$1.primitiveCount}) ?? 0)+node.childNodes.reduce(0,{$0+triangles($1)})
    }
    #if DEBUG
    func preview(_ theme:SpatialTheme) throws {
        let id=UUID(),root=SCNNode();root.addChildNode(try SpatialAssets.composition(theme));view.scene.rootNode.addChildNode(root)
        objects[id]=root;radii[id]=0.48;selected=id;hasSelection=true;visibility=true
    }
    #endif
    func addAnother() { selected=nil; hasSelection=false; placing=true; active=true; status="Toque em outra área livre. Máximo: 6 conjuntos." }
    func tap(_ point: CGPoint, tracking: Bool) {
        guard active,!panelBlocking,tracking,!recovering else { status="Espere o rastreamento estabilizar e recuperar o mapa salvo."; return }
        if !placing, let id=hit(point) {
            if selected==id { interact() } else { selected=id;hasSelection=true;markSelection();status="Selecionado. Toque novamente para interagir." }
            return
        }
        guard placing else { status="Toque em Adicionar para colocar outro conjunto."; return }
        guard objects.count<6 else { status="Limite de seis conjuntos para manter o desempenho."; return }
        let footprint=selectedModel.flatMap { SpatialDemo(rawValue:$0)?.radius } ?? (selectedModel == nil ? 0.48 : 0.24)
        guard let placement=placement(point,radius:footprint,ignoring:nil) else { return }
        do {
            let content=try content(), root=SCNNode()
            guard triangles(content)+objects.values.reduce(0,{ $0+triangles($1) })<=350000 else { status="Remova um objeto antes de adicionar outro modelo detalhado.";return }
            let id=UUID(),anchor=ARAnchor(name:"JarvisObject:"+id.uuidString,transform:placement.0)
            root.simdTransform=anchor.transform;root.addChildNode(content);root.isHidden = !visibility
            view.scene.rootNode.addChildNode(root);view.session.add(anchor:anchor)
            objects[id]=root;anchors[id]=anchor;supports[id]=placement.1;radii[id]=footprint
            remember(id,model:selectedModel ?? "theme:"+theme.rawValue)
            selected=id;objectCount=objects.count;hasSelection=true;placing=false;markSelection()
            status="Objeto fixado. Arraste, gire com dois dedos ou use pinça. Toque para interagir."
        } catch { status="Falha ao abrir o modelo local: \(error.localizedDescription)" }
    }
    private func hit(_ point: CGPoint) -> UUID? {
        for result in view.hitTest(point,options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]) {
            var node: SCNNode?=result.node
            while let current=node {
                if let id=objects.first(where:{$0.value===current})?.key { return id };node=current.parent
            }
        }
        return nil
    }
    func hand(_ sample:SpatialHandSample?) {
        guard active,!panelBlocking,visibility,!placing,!recovering else { handGesture.reset();palmScale=SpatialPalmScale();return }
        let id=sample.flatMap { hit($0.point) }
        let contact=sample.flatMap { sample -> Bool? in
            guard let p=sample.worldPoint,let hit=view.hitTest(sample.point,options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first else { return nil }
            let q=hit.worldCoordinates
            return simd_distance(p,SIMD3(q.x,q.y,q.z))<0.15
        } ?? false
        if let sample,sample.openPalm,let palm=sample.palmWorld,let selected,selected==id,let frame=view.session.currentFrame {
            let camera=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
            if let factor=palmScale.update(target:selected.uuidString,depth:Double(simd_distance(camera,palm)),time:sample.time) { resizeSelected(factor) }
        } else { palmScale=SpatialPalmScale() }
        for event in handGesture.update(ratio:sample?.worldPoint == nil ? .nan : sample!.ratio,pointing:sample?.pointing == true && contact,target:contact ? id?.uuidString : nil,time:sample?.time ?? ProcessInfo.processInfo.systemUptime) {
            switch event {
            case .press(let key):
                selected=UUID(uuidString:key);hasSelection=selected != nil;markSelection()
                if let selected,let node=objects[selected],let p=sample?.worldPoint { handOffset=node.simdWorldPosition-p }
            case .drag(let key):
                guard let id=UUID(uuidString:key),let node=objects[id],let p=sample?.worldPoint else { continue }
                handDragging=id;node.simdPosition=p+handOffset
            case .release:
                if let id=handDragging { reanchor(id);handDragging=nil }
            case .cancel:if let id=handDragging { reanchor(id);handDragging=nil }
            case .click(let key):selected=UUID(uuidString:key);hasSelection=selected != nil;markSelection();interact()
            }
        }
    }
    func resizeSelected(_ factor: Float) {
        guard visibility,let selected,let node=objects[selected],factor.isFinite else { return }
        let scale=min(2,max(0.25,node.simdScale.x*factor))
        if let support=supports[selected],let plane=planes[support],!fits(SIMD4(node.simdPosition,1),radius:radius(selected)*scale,on:plane,ignoring:selected) { status="Esse tamanho ultrapassa a superfície livre.";return }
        node.simdScale=SIMD3(repeating:scale);remember(selected)
    }
    func moveSelected(x: Float,z: Float) {
        guard visibility,!recovering,x.isFinite,z.isFinite,let selected,let node=objects[selected] else { return }
        let destination=node.simdPosition+SIMD3(x,0,z)
        guard let support=supports[selected],let plane=planes[support],fits(SIMD4(destination,1),radius:radius(selected)*node.simdScale.x,on:plane,ignoring:selected) else {
            status="Mapeie a superfície antes de mover o objeto por comando.";return
        }
        node.simdPosition=destination;reanchor(selected)
    }
    /// Whole footprint must fit measured support. No placement on an estimated
    /// infinite plane, through walls, in doorways, or on an unmapped passage.
    private func placement(_ point: CGPoint, radius: Float, ignoring: UUID?) -> (simd_float4x4,UUID)? {
        let panelSurface=selectedModel == SpatialDemo.panel.rawValue
        guard let query=view.raycastQuery(from:point,allowing:.existingPlaneGeometry,alignment:panelSurface ? .any : .horizontal),
              let result=view.session.raycast(query).first, let plane=result.anchor as? ARPlaneAnchor,
              plane.classification == .floor || plane.classification == .table || (panelSurface && plane.classification == .wall) else {
            status="Mostre mais do piso ou da mesa. Não coloco objetos em área desconhecida.";return nil
        }
        let p=result.worldTransform.columns.3
        guard fits(p,radius:radius,on:plane,ignoring:ignoring) else {
            status="Muito perto de uma borda, parede, porta ou outro objeto. Escolha uma área livre.";return nil
        }
        var transform=matrix_identity_float4x4; transform.columns.3=p
        if plane.alignment == .vertical {
            var normal=SIMD3(plane.transform.columns.1.x,0,plane.transform.columns.1.z)
            guard simd_length(normal)>0.1 else { return nil };normal=simd_normalize(normal)
            if let frame=view.session.currentFrame {
                let camera=SIMD3(frame.camera.transform.columns.3.x-p.x,0,frame.camera.transform.columns.3.z-p.z)
                if simd_dot(normal,camera)<0 { normal = -normal }
            }
            let right=simd_cross(SIMD3<Float>(0,1,0),normal)
            transform.columns.0=SIMD4(right,0);transform.columns.1=SIMD4(0,1,0,0);transform.columns.2=SIMD4(normal,0)
            transform.columns.3 += SIMD4(normal*0.025,0)
        }
        return (transform,plane.identifier)
    }
    private func fits(_ p: SIMD4<Float>,radius: Float,on plane: ARPlaneAnchor,ignoring: UUID?) -> Bool {
        let local=simd_inverse(plane.transform)*p
        let polygon=plane.geometry.boundaryVertices.map { SIMD2<Float>($0.x,$0.z) }
        for i in 0..<16 {
            let angle=Float(i)*2*Float.pi/16
            guard MeasuredWall.contains(SIMD2<Float>(local.x+cos(angle)*radius,local.z+sin(angle)*radius),polygon:polygon) else { return false }
        }
        for other in planes.values where other.alignment == .vertical && other.identifier != plane.identifier {
            let q=simd_inverse(other.transform)*p
            if abs(q.y)<radius+0.10 && abs(q.x-other.center.x)<other.extent.x/2+radius && abs(q.z-other.center.z)<other.extent.z/2+0.55 { return false }
        }
        for (id,node) in objects where id != ignoring {
            let other=node.simdWorldPosition
            if simd_distance(SIMD2<Float>(p.x,p.z),SIMD2<Float>(other.x,other.z))<radius+self.radius(id)*node.simdScale.x { return false }
        }
        return true
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard active,!panelBlocking,visibility,!placing else { return }
        if gesture.state == .began { selected=hit(gesture.location(in:view));hasSelection=selected != nil;markSelection() }
        guard let id=selected, let node=objects[id], let result=placement(gesture.location(in:view),radius:radius(id)*node.simdScale.x,ignoring:id) else { return }
        node.simdPosition=SIMD3<Float>(result.0.columns.3.x,result.0.columns.3.y,result.0.columns.3.z);supports[id]=result.1
        if gesture.state == .ended || gesture.state == .cancelled { reanchor(id) }
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard active,!panelBlocking,visibility, let id=selected,let node=objects[id],let support=supports[id],let plane=planes[support] else { return }
        if gesture.state == .began { initialScale=node.simdScale.x }
        let scale=min(2,max(0.25,initialScale*Float(gesture.scale)))
        guard fits(SIMD4<Float>(node.simdPosition,1),radius:radius(id)*scale,on:plane,ignoring:id) else { status="Esse tamanho ultrapassa a área livre.";return }
        node.simdScale=SIMD3<Float>(repeating:scale)
        if gesture.state == .ended { reanchor(id) }
    }
    @objc private func rotate(_ gesture: UIRotationGestureRecognizer) {
        guard active,!panelBlocking,visibility, let id=selected, let node=objects[id] else { return }
        if gesture.state == .began { initialAngle=node.eulerAngles.y }
        node.eulerAngles.y=initialAngle-Float(gesture.rotation)
        if gesture.state == .ended { reanchor(id) }
    }
    private func reanchor(_ id: UUID) {
        guard let root=objects[id],let old=anchors[id] else { return }
        view.session.remove(anchor:old)
        var pose=root.simdTransform
        for c in 0..<3 { let v=SIMD3(pose[c].x,pose[c].y,pose[c].z)/root.simdScale.x;pose[c]=SIMD4(v,0) }
        let new=ARAnchor(name:"JarvisObject:"+id.uuidString,transform:pose)
        anchors[id]=new;view.session.add(anchor:new);remember(id)
    }
    func interact() {
        guard visibility, let id=selected,let root=objects[id] else { return }
        UIImpactFeedbackGenerator(style:.medium).impactOccurred()
        if let car=root.childNode(withName:"movingCar",recursively:true) {
            if car.action(forKey:"drive") != nil { car.removeAction(forKey:"drive");car.position=SCNVector3(0,0.005,0);status="Carro parado." }
            else { car.runAction(.repeatForever(.sequence([.moveBy(x:0,y:0,z:0.12,duration:1.2),.moveBy(x:0,y:0,z:-0.12,duration:1.2)])),forKey:"drive");status="Carro em movimento dentro da base." }
        } else if let glow=root.childNode(withName:"roomLight",recursively:true) {
            glow.isHidden.toggle();status=glow.isHidden ? "Luz da sala apagada." : "Luz da sala acesa."
        } else if let fish=root.childNode(withName:"fishOrbit",recursively:true) {
            fish.isPaused.toggle();status=fish.isPaused ? "Peixe parado." : "Peixe nadando."
        } else if let object=root.childNode(withName:"catalogObject",recursively:true) {
            if object.action(forKey:"inspect") != nil { object.removeAction(forKey:"inspect");status="Giro parado." }
            else { object.runAction(.repeatForever(.rotateBy(x:0,y:.pi*2,z:0,duration:18)),forKey:"inspect");status="Giro de inspeção. Toque novamente para parar." }
        } else if root.childNode(withName:"radio",recursively:true) != nil {
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
                let ring=SCNNode(geometry:SCNTorus(ringRadius:CGFloat(radius(id)-0.02),pipeRadius:0.002));ring.name="selection";ring.position.y=0.003
                ring.geometry?.firstMaterial?.lightingModel = .constant;ring.geometry?.firstMaterial?.diffuse.contents=UIColor.cyan
                root.addChildNode(ring)
            }
        }
    }
    func removeSelected() {
        guard let id=selected else { return }
        if playingID==id { player?.stop();playingID=nil }
        objects.removeValue(forKey:id)?.removeFromParentNode();supports.removeValue(forKey:id);radii.removeValue(forKey:id)
        records.removeValue(forKey:id);revision+=1
        if let anchor=anchors.removeValue(forKey:id) { view.session.remove(anchor:anchor) }
        selected=nil;hasSelection=false;objectCount=objects.count;status="Conjunto removido."
    }
    func update(_ anchor: ARAnchor) {
        if let plane=anchor as? ARPlaneAnchor { planes[plane.identifier]=plane }
        if let id=anchors.first(where:{$0.value.identifier==anchor.identifier})?.key,id != handDragging,let root=objects[id] {
            let scale=root.simdScale;root.simdTransform=anchor.transform;root.simdScale=scale;anchors[id]=anchor
        }
        guard let name=anchor.name,name.hasPrefix("JarvisObject:"),let id=UUID(uuidString:String(name.dropFirst("JarvisObject:".count))),
              let record=restored[id],record.anchor==anchor.identifier else { return }
        do {
            let node:SCNNode
            if record.model.hasPrefix("theme:"),let value=SpatialTheme(rawValue:String(record.model.dropFirst(6))) { node=try SpatialAssets.composition(value) }
            else if let demo=SpatialDemo(rawValue:record.model) { node=try demo.make() }
            else { let holder=SCNNode();let mesh=try SpatialAssets.load(record.model);mesh.simdScale=SIMD3(repeating:0.3);holder.addChildNode(mesh);node=holder }
            let root=SCNNode();root.addChildNode(node);root.simdTransform=anchor.transform;root.simdScale=SIMD3(repeating:record.scale);root.isHidden = !visibility
            objects[id]=root;anchors[id]=anchor;radii[id]=SpatialDemo(rawValue:record.model)?.radius ?? (record.model.hasPrefix("theme:") ? 0.48 : 0.24)
            view.scene.rootNode.addChildNode(root);restored.removeValue(forKey:id);objectCount=objects.count
            if restored.isEmpty { persistenceStatus="Âncoras recuperadas. Aguardando rastreamento estável para exibir." }
        } catch { persistenceStatus="Modelo salvo indisponível: \(record.model). Dados preservados." }
    }
    func remove(_ anchor: ARAnchor) { planes.removeValue(forKey:anchor.identifier) }
    func setVisible(_ value: Bool) {
        let allowed=value && !recovering
        guard allowed != visibility else { return }
        if !allowed { if let id=handDragging { reanchor(id);handDragging=nil };handGesture.reset();palmScale=SpatialPalmScale() }
        visibility=allowed;objects.values.forEach { $0.isHidden = !allowed }
        if !allowed { player?.pause() }
        else if playingID != nil { player?.play() }
    }
    func setThermal(_ thermal: ProcessInfo.ThermalState) {
        let paused=thermal == .serious || thermal == .critical
        guard paused != thermalPaused else { return }; thermalPaused=paused
        objects.values.forEach { $0.isPaused=paused }
    }
    func stop() {
        player?.stop();player=nil
        objects.values.forEach { $0.removeFromParentNode() };objects.removeAll();anchors.removeAll();planes.removeAll();radii.removeAll();SpatialAssets.clear()
    }
}

struct SpatialControls: View {
    @ObservedObject var world: SpatialWorld
    @State private var catalogPage=0
    @State private var catalogOpen=false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ScrollView(.horizontal,showsIndicators:false) { HStack {
                ForEach(SpatialTheme.allCases,id:\.rawValue) { theme in
                    Button { world.setTheme(theme) } label: { Label(theme.title,systemImage:theme.symbol).font(.caption) }
                        .buttonStyle(.bordered).tint(world.theme == theme ? .cyan : .gray)
                }
            }
            }
            Button(catalogOpen ? "Fechar catálogo" : "\(SpatialAssets.catalog.count) modelos · abrir catálogo",systemImage:"cube.transparent") { catalogOpen.toggle() }.font(.caption)
            if catalogOpen {
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:6) {
                    ForEach(Array(SpatialAssets.catalog.dropFirst(catalogPage*4).prefix(4))) { item in
                        Button(item.title) { world.setModel(item.id);catalogOpen=false }.font(.caption).buttonStyle(.bordered)
                    }
                }
                HStack {
                    Button("Anterior") { catalogPage=max(0,catalogPage-1) }.disabled(catalogPage==0)
                    Text("\(catalogPage+1)/\(max(1,(SpatialAssets.catalog.count+3)/4))").font(.caption.monospacedDigit())
                    Button("Próxima") { catalogPage+=1 }.disabled((catalogPage+1)*4>=SpatialAssets.catalog.count)
                }.font(.caption)
            }
            Text(world.status).font(.caption).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("Adicionar",systemImage:"plus") { world.addAnother() }.disabled(world.objectCount>=6)
                Button("Interagir",systemImage:"hand.tap") { world.interact() }.disabled(!world.hasSelection)
                Button("Remover",systemImage:"trash") { world.removeSelected() }.disabled(!world.hasSelection)
            }.buttonStyle(.bordered).controlSize(.small)
            HStack {
                Button("Quarto") { world.chooseRoom("Quarto") }
                Button("Sala") { world.chooseRoom("Sala") }
                Text(world.roomName).font(.caption)
                Button("Salvar mapa") { world.saveMap() }
            }.font(.caption).buttonStyle(.bordered)
            ScrollView(.horizontal) { HStack {
                ForEach(SpatialDemo.allCases,id:\.rawValue) { demo in Button(demo.title) { world.setModel(demo.rawValue) }.buttonStyle(.bordered) }
            }}.font(.caption)
            Text(world.persistenceStatus).font(.caption2).foregroundStyle(.secondary)
            ShareLink("Compartilhar diagnóstico",item:SpatialArchive.file.deletingLastPathComponent().appendingPathComponent("diagnostics.json")).font(.caption)
        }
    }
}
