import SwiftUI
import ARKit
import SceneKit
import CryptoKit

struct ScannedRoomManifest:Decodable {
    struct Plane:Decodable { let id:Int;let kind:String;let normal:[Float];let center:[Float];let indices:String;var sourcePlaneIDs:[Int]?=nil }
    struct File:Decodable { let file:String;let bytes:Int;let sha256:String }
    let sourceSHA256:String;let mesh:String;let texture:String;let previewIndices:String;let facePlanes:String
    let floorY:Float;let lower:[Float];let upper:[Float];let planes:[Plane];let files:[File]
    var cleanScene:String?=nil
    var sceneProfile:String?=nil
}

/// Personal capture stays in the installed bundle, outside the public repository.
/// One metric registration places the scan in ARKit; GPS never supplies this pose.
@MainActor final class ScannedRoomWall:ObservableObject {
    @Published private(set) var status="Alinhe a captura do quarto antes de testar a parede."
    @Published private(set) var sourcePoints:[SIMD3<Float>]=[]
    @Published private(set) var matching=false
    @Published private(set) var armed=false
    @Published private(set) var aligned=false
    private(set) var manifest:ScannedRoomManifest?
    private var base:SCNGeometry?
    @Published private(set) var forestActive=false
    private var forestModel:SCNNode?
    private var forestNode:SCNNode?
    private var captureCache:RoomForestRegistration.Capture?
    private var doorway:RoomDoorwayOpening?
    private var hitFaces:Data?
    private var gameFloors:[Int:[SIMD3<Float>]]=[:]
    private var cleanCapture:(base:SCNGeometry,manifest:ScannedRoomManifest,faces:Data)?
    private func forestCapture()->(base:SCNGeometry,manifest:ScannedRoomManifest,faces:Data)? {
        if let cleanCapture { return cleanCapture }
        guard let manifest,let base,let faces else { return nil }
        if let name=manifest.cleanScene {
            do {
                let clean=try JSONDecoder().decode(ScannedRoomManifest.self,from:data(name))
                guard clean.sourceSHA256==manifest.sourceSHA256,clean.sceneProfile=="clean-game-v1" else { throw CocoaError(.fileReadCorruptFile) }
                let model=try SpatialAssets.partNode(["baseColor":[1.0,1.0,1.0,1.0]],mesh:clean.mesh)
                let labels=try data(clean.facePlanes)
                guard let geometry=model.geometry,labels.count==(geometry.elements.first?.primitiveCount ?? -1)*4 else { throw CocoaError(.fileReadCorruptFile) }
                cleanCapture=(geometry,clean,labels);return cleanCapture
            } catch { status="A reconstrução limpa falhou na verificação. A captura original foi preservada.";return nil }
        }
        return (base,manifest,faces)
    }
    private func buildForest()->SCNNode? {
        guard let capture=forestCapture() else { return nil }
        return RoomForestScene.make(base:capture.base,manifest:capture.manifest,assignments:capture.faces,opening:doorway)
    }
    private func updateCollision(forest:Bool) {
        guard let root,let base,let faces else { return }
        var geometry=base,labels=faces
        if let clean=forestCapture() { geometry=clean.base;labels=clean.faces }
        if let doorway { (geometry,labels)=RoomForestScene.cut(base:geometry,assignments:labels,opening:doorway) }
        let collider=SCNGeometry(sources:geometry.sources,elements:geometry.elements)
        let material=SCNMaterial();material.colorBufferWriteMask=[];material.readsFromDepthBuffer=true;material.isDoubleSided=true
        collider.materials=[material];RoomForestScene.setCapturedDepth(collider,forest:forest)
        root.geometry=collider;hitFaces=labels
    }
    func support(_ world:SIMD3<Float>,radius:Float)->UUID? {
        guard tracking,let pose,let anchor,let capture=forestCapture(),capture.manifest.sceneProfile=="clean-game-v1" else { return nil }
        let local=simd_inverse(pose)*SIMD4(world,1)
        return RoomForestScene.supports(base:capture.base,manifest:capture.manifest,assignments:capture.faces,point:SIMD3(local.x,local.y,local.z),radius:radius) ? anchor.identifier : nil
    }
    func placement(_ point:CGPoint,radius:Float)->(simd_float4x4,UUID)? {
        guard aligned,tracking,let root,let hit=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first(where:{$0.node===root}),abs(hit.worldNormal.y)>0.8 else { return nil }
        let p=SIMD3<Float>(hit.worldCoordinates)
        guard let support=support(p,radius:radius) else { return nil }
        var transform=matrix_identity_float4x4;transform.columns.3=SIMD4(p,1);return (transform,support)
    }
    func portalPlacement(_ point:CGPoint,width:Float,height:Float)->(simd_float4x4,Int)? {
        guard tracking,let root,let geometry=root.geometry,let labels=hitFaces,let frame=view.session.currentFrame,
              let hit=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first(where:{$0.node===root}),abs(hit.worldNormal.y)<0.2 else { return nil }
        let kinds=labels.withUnsafeBytes{b in (0..<(labels.count/4)).map{Int(b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self))}}
        guard hit.faceIndex>=0,hit.faceIndex<kinds.count else { return nil }
        let id=kinds[hit.faceIndex]
        guard forestCapture()?.manifest.planes.contains(where:{$0.id==id && $0.kind=="wall"}) == true else { return nil }
        var n=simd_normalize(SIMD3<Float>(hit.worldNormal)),p=SIMD3<Float>(hit.worldCoordinates)
        let eye=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        if simd_dot(eye-p,n)<0 { n = -n };let u=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),n))
        let pose=simd_float4x4(SIMD4(u,0),SIMD4(0,1,0,0),SIMD4(n,0),SIMD4(p,1)),local=simd_inverse(pose)*root.simdTransform
        let vertices=RoomForestScene.points(geometry),indices=RoomForestScene.indices(geometry)
        var wall:[SIMD2<Float>]=[]
        for face in kinds.indices where kinds[face]==id {
            for j in 0..<3 { let q=local*SIMD4(vertices[Int(indices[face*3+j])],1);if abs(q.z)<0.12 { wall.append(SIMD2(q.x,q.y)) } }
        }
        guard wall.count%3==0,SpatialPortalMath.fitsWall(width:width,height:height,triangles:wall) else { return nil }
        var raised=pose;raised.columns.3 += SIMD4(n*0.025,0);return (raised,id)
    }
    func setDoorway(_ opening:RoomDoorwayOpening) {
        guard let pose else { return }
        let active=forestActive
        _ = setForest(false);doorway=RoomDoorwayOpening(pose:simd_inverse(pose)*opening.pose,width:opening.width,height:opening.height);forestModel=nil
        forestModel=buildForest();updateCollision(forest:false)
        if active { _ = setForest(true) }
    }
    var pose:simd_float4x4? { aligned ? root?.simdTransform : nil }
    var supportIdentifier:UUID? { aligned ? anchor?.identifier : nil }
    var floorCenter:SIMD3<Float>? {
        guard let m=manifest,let p=m.planes.first(where:{$0.kind=="floor"}),p.center.count==3 else { return nil }
        return SIMD3(p.center[0],m.floorY,p.center[2])
    }
    func gameSpots(radius:Float=0.30)->[SIMD3<Float>] {
        let key=Int(radius*100)
        if let cached=gameFloors[key] { return cached }
        guard let base,let manifest,let faces else { return [] }
        let spots=RoomForestScene.floorSpots(base:base,manifest:manifest,assignments:faces,radius:radius);gameFloors[key]=spots;return spots
    }
    func sourceCapture()->RoomForestRegistration.Capture? {
        if let captureCache { return captureCache }
        guard prepare(),let base,let manifest,let faces else { return nil }
        let capture=RoomForestScene.capture(base:base,manifest:manifest,assignments:faces);captureCache=capture;return capture
    }
    func registerAutomatically(_ live:RoomForestRegistration.Capture) async -> Bool {
        guard let source=sourceCapture() else { return false }
        let fit=await Task.detached(priority:.userInitiated) { RoomForestRegistration.fit(source:source,live:live) }.value
        guard !Task.isCancelled else { return false }
        guard let fit else { status="Não confirmei um encaixe único. Diga calibrar floresta e mostre três paredes, um canto e um móvel.";return false }
        clear();let anchor=ARAnchor(name:"JarvisScannedRoom",transform:fit.pose);install(anchor);view.session.add(anchor:anchor)
        status="Captura reconhecida pela geometria · erro médio \(Int(fit.error*100)) cm."
        onChange?();onRegistered?();return true
    }
    func forestPreview(excludingWall:Int?=nil)->SCNNode? {
        guard prepare(),let base,let m=manifest,let faces else { return nil }
        if forestModel==nil { forestModel=buildForest() }
        guard let node=forestModel?.clone() else { return nil }
        if let excludingWall {
            let mapped=forestCapture()?.manifest.planes.first{($0.sourcePlaneIDs ?? [$0.id]).contains(excludingWall)}?.id ?? excludingWall
            node.childNode(withName:"RoomForest-plane-\(mapped)",recursively:true)?.removeFromParentNode()
        }
        return node
    }
    @discardableResult func setForest(_ value:Bool)->Bool {
        guard value != forestActive else { return true }
        if value {
            guard aligned,let root,let node=forestPreview() else { status="Primeiro preciso reconhecer o quarto capturado.";return false }
            node.categoryBitMask=1;root.addChildNode(node);forestNode=node
        } else { forestNode?.removeFromParentNode();forestNode=nil }
        // The raw scan remains a hit-test collider, but must not punch noisy
        // depth holes through its reconstructed visible replacement.
        updateCollision(forest:value)
        if value,let environment=Bundle.main.url(forResource:"Portal_forest_slope_2k",withExtension:"hdr") {
            view.scene.lightingEnvironment.contents=environment;view.scene.lightingEnvironment.intensity=0.65
        } else { view.scene.lightingEnvironment.contents=nil }
        forestActive=value;onChange?();return true
    }
    func wallID(at point:CGPoint)->Int? {
        guard aligned,let root,let faces=hitFaces ?? faces,let m=manifest,
              let hit=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first(where:{$0.node===root}),hit.faceIndex>=0,hit.faceIndex*4+4<=faces.count else { return nil }
        let id=Int(faces.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:hit.faceIndex*4,as:Int32.self)})
        return m.planes.contains(where:{$0.id==id && $0.kind=="wall"}) ? id : nil
    }
    private var faces:Data?
    private var realPoints:[SIMD3<Float>]=[]
    private var anchor:ARAnchor?
    private var root:SCNNode?
    private var patch:SCNNode?
    private var chosen:Int?
    private var style="white"
    private var tracking=false
    private var markers=SCNNode()
    private var dwell=SpatialGesture()
    private let view:ARSCNView
    var onChange:(()->Void)?
    var onRegistered:(()->Void)?
    init(view:ARSCNView) { self.view=view }
    private func data(_ name:String)throws->Data {
        guard name==URL(fileURLWithPath:name).lastPathComponent,
              let url=Bundle.main.url(forResource:name,withExtension:nil) else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf:url)
    }
    @discardableResult func prepare()->Bool {
        if base != nil { return true }
        do {
            let m=try JSONDecoder().decode(ScannedRoomManifest.self,from:data("RoomScanManifest.json"))
            guard m.lower.count==3,m.upper.count==3,m.planes.count<=64 else { throw CocoaError(.fileReadCorruptFile) }
            for f in m.files {
                let bytes=try data(f.file)
                guard bytes.count==f.bytes,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==f.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            }
            let node=try SpatialAssets.partNode(["Color":m.texture,"doubleSided":true],mesh:m.mesh)
            guard let geometry=node.geometry,let element=geometry.elements.first else { throw CocoaError(.fileReadCorruptFile) }
            let assignments=try data(m.facePlanes)
            guard assignments.count==element.primitiveCount*4 else { throw CocoaError(.fileReadCorruptFile) }
            manifest=m;base=geometry;faces=assignments;return true
        } catch { status="A captura privada do quarto não está disponível ou falhou na verificação.";return false }
    }
    func previewScene()->SCNScene {
        let scene=SCNScene();scene.background.contents=UIColor(red:0.02,green:0.05,blue:0.08,alpha:1)
        guard prepare(),let m=manifest,let base,let indices=try? data(m.previewIndices) else { return scene }
        let geometry=SCNGeometry(sources:base.sources,elements:[SCNGeometryElement(data:indices,primitiveType:.triangles,primitiveCount:indices.count/12,bytesPerIndex:4)])
        geometry.materials=base.materials;scene.rootNode.addChildNode(SCNNode(geometry:geometry))
        let center=SIMD3<Float>((m.lower[0]+m.upper[0])/2,m.floorY,(m.lower[2]+m.upper[2])/2)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zFar=50
        camera.simdPosition=center+SIMD3(0,8,5);camera.look(at:SCNVector3(center));scene.rootNode.addChildNode(camera)
        return scene
    }
    func pickSource(_ result:SCNHitTestResult,in scene:SCNScene) {
        guard sourcePoints.count<3,let m=manifest else { return }
        let p=SIMD3<Float>(result.worldCoordinates)
        guard abs(p.y-m.floorY)<0.15 else { status="Escolha três detalhes do piso, afastados e formando um triângulo.";return }
        guard sourcePoints.allSatisfy({simd_distance($0,p)>0.4}) else { status="Os pontos precisam ficar a mais de 40 cm um do outro.";return }
        sourcePoints.append(p);addMarker(p,number:sourcePoints.count,parent:scene.rootNode)
        status="Ponto \(sourcePoints.count)/3 na captura. Use os mesmos detalhes no piso real."
    }
    func resetSource() { sourcePoints=[];status="Marque três detalhes reconhecíveis do piso na captura." }
    func beginMatching() {
        guard sourcePoints.count==3 else { return };realPoints=[];matching=true;armed=false
        markers.removeFromParentNode();markers=SCNNode();view.scene.rootNode.addChildNode(markers)
        status="No piso real, toque no mesmo ponto 1/3 escolhido na captura."
    }
    func cancelMatching() { matching=false;realPoints=[];markers.removeFromParentNode() }
    private func addMarker(_ p:SIMD3<Float>,number:Int,parent:SCNNode) {
        let n=SCNNode(geometry:SCNSphere(radius:0.025));n.simdPosition=p;n.geometry?.firstMaterial?.diffuse.contents=UIColor.orange
        let label=SCNText(string:String(number),extrusionDepth:0);label.font=UIFont.boldSystemFont(ofSize:1);label.firstMaterial?.diffuse.contents=UIColor.white
        let text=SCNNode(geometry:label);text.scale=SCNVector3(0.06,0.06,0.06);text.position=SCNVector3(0,0.035,0);text.constraints=[SCNBillboardConstraint()];n.addChildNode(text);parent.addChildNode(n)
    }
    @discardableResult func tap(_ point:CGPoint)->Bool {
        if matching {
            guard tracking,let frame=view.session.currentFrame else { return true }
            var world:SIMD3<Float>?
            if let query=view.raycastQuery(from:point,allowing:.existingPlaneGeometry,alignment:.horizontal),
               let hit=view.session.raycast(query).first,let plane=hit.anchor as? ARPlaneAnchor,
               plane.classification == .floor {
                world=SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z)
            }
            if world == nil {
                let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
                let uv=CGPoint(x:point.x/view.bounds.width,y:point.y/view.bounds.height).applying(frame.displayTransform(for:orientation,viewportSize:view.bounds.size).inverted())
                world=SpatialHandMath.worldPoint(uv,frame:frame)
            }
            guard let world else { status="Aproxime o ponto do piso e mova a câmera devagar para ler a profundidade.";return true }
            realPoints.append(world);addMarker(world,number:realPoints.count,parent:markers)
            if realPoints.count==3 {
                guard let pose=SpatialRoomAlignment.fit(source:sourcePoints,target:realPoints) else {
                    realPoints=[];markers.childNodes.forEach{$0.removeFromParentNode()};status="Os pontos não coincidem em escala. Repita os três pontos na mesma ordem.";return true
                }
                clear();let anchor=ARAnchor(name:"JarvisScannedRoom",transform:pose)
                install(anchor);view.session.add(anchor:anchor);matching=false;markers.removeFromParentNode()
                status="Captura alinhada. Escolha Parede branca ou Tijolos e aponte para uma parede."
                onChange?();onRegistered?()
            } else { status="Toque no mesmo ponto \(realPoints.count+1)/3 do piso real." }
            return true
        }
        guard armed,tracking,let root,let faces=hitFaces ?? faces,let m=manifest else { return false }
        let hits=view.hitTest(point,options:[.categoryBitMask:16,.searchMode:SCNHitTestSearchMode.closest.rawValue,.backFaceCulling:false])
        guard let hit=hits.first(where:{$0.node===root}),hit.faceIndex>=0,hit.faceIndex*4+4<=faces.count else { return true }
        let id=Int(faces.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:hit.faceIndex*4,as:Int32.self)})
        guard m.planes.contains(where:{$0.id==id && $0.kind=="wall"}) else { status="Esse ponto não pertence a uma parede da captura. Aponte para a superfície vertical.";return true }
        paint(id);armed=false;onChange?();return true
    }
    func arm(_ value:String) {
        guard prepare(),aligned else { status="Primeiro alinhe a captura por três pontos do piso.";return }
        style=value=="brick" ? "brick" : "white";armed=true;dwell.reset()
        status="Aponte o indicador por dois segundos para uma parede, ou toque nela, para aplicar \(style=="brick" ? "tijolos" : "branco")."
    }
    func hand(_ sample:SpatialHandSample?)->Double {
        guard armed,tracking else { dwell.reset();return 0 }
        // The same dwell policy as projected controls; no pinch can paint a wall.
        if let sample {
            for event in dwell.update(ratio:.nan,pointing:sample.pointing,target:wallTarget(sample.point),time:sample.time) {
                if case .click=event { _=tap(sample.point) }
            }
        } else { dwell.reset() }
        return dwell.progress
    }
    private func wallTarget(_ point:CGPoint)->String? {
        guard let root,let faces=hitFaces ?? faces,let m=manifest,
              let hit=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first(where:{$0.node===root}),
              hit.faceIndex>=0,hit.faceIndex*4+4<=faces.count else { return nil }
        let id=Int(faces.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:hit.faceIndex*4,as:Int32.self)})
        return m.planes.contains(where:{$0.id==id && $0.kind=="wall"}) ? "wall:\(id)" : nil
    }
    private func install(_ anchor:ARAnchor) {
        guard let base else { return };self.anchor=anchor
        let geometry=SCNGeometry(sources:base.sources,elements:base.elements),material=SCNMaterial()
        material.colorBufferWriteMask=[];material.writesToDepthBuffer=true;material.readsFromDepthBuffer=true;material.isDoubleSided=true
        geometry.materials=[material]
        let node=SCNNode(geometry:geometry);node.categoryBitMask=16;node.simdTransform=anchor.transform;node.renderingOrder = -50
        root=node;hitFaces=faces;view.scene.rootNode.addChildNode(node);aligned=true;node.isHidden = !tracking;updateCollision(forest:false)
    }
    private func paint(_ id:Int) {
        guard let base,let root,let m=manifest,let p=m.planes.first(where:{$0.id==id && $0.kind=="wall"}),p.normal.count==3,
              let indices=try? data(p.indices),let vertex=base.sources(for:.vertex).first else { return }
        patch?.removeFromParentNode()
        let n=SIMD3<Float>(p.normal[0],p.normal[1],p.normal[2]),u=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),n))
        var uv:[SIMD2<Float>]=[]
        vertex.data.withUnsafeBytes { bytes in
            for i in 0..<vertex.vectorCount {
                let offset=vertex.dataOffset+i*vertex.dataStride
                let x=bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),y=bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self),z=bytes.loadUnaligned(fromByteOffset:offset+8,as:Float.self)
                uv.append(SIMD2(simd_dot(SIMD3(x,y,z),u),y))
            }
        }
        let tex=uv.withUnsafeBytes{Data($0)}
        let sources=base.sources.filter{$0.semantic != .texcoord}+[SCNGeometrySource(data:tex,semantic:.texcoord,vectorCount:uv.count,usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:0,dataStride:8)]
        let geometry=SCNGeometry(sources:sources,elements:[SCNGeometryElement(data:indices,primitiveType:.triangles,primitiveCount:indices.count/12,bytesPerIndex:4)])
        let material=WallMaterials.make(.white)
        if style=="brick" {
            material.multiply.contents=UIColor.white
            for (prop,key) in [(material.diffuse,"Color"),(material.normal,"NormalGL"),(material.roughness,"Roughness")] {
                if let path=Bundle.main.path(forResource:"RoomFX_brick_"+key,ofType:"jpg") { prop.contents=UIImage(contentsOfFile:path) }
                prop.contentsTransform=SCNMatrix4MakeScale(1/0.75,1/0.75,1)
            }
            material.normal.intensity=0.5
        }
        geometry.materials=[material];let node=SCNNode(geometry:geometry);node.categoryBitMask=1;node.renderingOrder=0
        let camera=view.session.currentFrame?.camera.transform.columns.3 ?? SIMD4(0,0,0,1)
        let local=simd_inverse(root.simdTransform)*camera,center=p.center.count==3 ? SIMD3(p.center[0],p.center[1],p.center[2]) : SIMD3<Float>.zero
        let sign:Float=simd_dot(SIMD3(local.x,local.y,local.z)-center,n)>=0 ? 1 : -1
        node.simdPosition=n*(sign*0.008);root.addChildNode(node);patch=node;chosen=id
        status="Parede \(id) aplicada aos triângulos capturados. Vãos da malha permanecem abertos."
    }
    func clearPaint() { patch?.removeFromParentNode();patch=nil;chosen=nil;armed=false;onChange?() }
    func cancelPaint() { armed=false;dwell.reset() }
    func setTracking(_ value:Bool) { tracking=value;root?.isHidden = !value }
    func update(_ anchor:ARAnchor) { if anchor.identifier==self.anchor?.identifier { self.anchor=anchor;root?.simdTransform=anchor.transform } }
    func snapshot()->SpatialScannedRoomRecord? {
        guard let anchor,let m=manifest else { return nil }
        return SpatialScannedRoomRecord(anchor:anchor.identifier,transform:SpatialArchive.values(anchor.transform),sourceSHA256:m.sourceSHA256,plane:chosen,style:style,forest:forestActive)
    }
    @discardableResult func restore(_ saved:SpatialScannedRoomRecord,anchor:ARAnchor)->Bool {
        guard prepare(),manifest?.sourceSHA256==saved.sourceSHA256 else { return false }
        clear();style=saved.style;install(anchor);if let id=saved.plane { paint(id) };_ = setForest(saved.forest ?? false);return true
    }
    func clear(preserveAnchor:Bool=false) {
        if !preserveAnchor,let anchor { view.session.remove(anchor:anchor) }
        root?.removeFromParentNode();root=nil;patch=nil;anchor=nil;chosen=nil;aligned=false;armed=false;forestNode=nil;forestActive=false;doorway=nil;forestModel=nil
        cancelMatching()
    }
}

@MainActor struct ScannedRoomPicker:UIViewRepresentable {
    let room:ScannedRoomWall
    func makeCoordinator()->Coordinator { Coordinator(room) }
    func makeUIView(context:Context)->SCNView {
        let v=SCNView();v.scene=room.previewScene();v.allowsCameraControl=true;v.autoenablesDefaultLighting=true
        v.backgroundColor = .black;v.antialiasingMode = .multisampling4X
        v.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:))));return v
    }
    func updateUIView(_ uiView:SCNView,context:Context) {}
    @MainActor final class Coordinator:NSObject {
        let room:ScannedRoomWall;init(_ room:ScannedRoomWall){self.room=room}
        @objc func tap(_ gesture:UITapGestureRecognizer) {
            guard let view=gesture.view as? SCNView,let scene=view.scene,
                  let hit=view.hitTest(gesture.location(in:view)).first else { return }
            room.pickSource(hit,in:scene)
        }
    }
}

struct ScannedRoomSetup:View {
    @ObservedObject var room:ScannedRoomWall
    let begin:()->Void
    var body:some View {
        VStack {
            Text("Alinhar captura do quarto").font(.headline)
            Text("Gire a captura e toque em três detalhes do piso, formando um triângulo. Depois marque os mesmos pontos no quarto real.").font(.caption).padding(.horizontal)
            ScannedRoomPicker(room:room)
            Text(room.status).font(.caption).padding()
            Button("Usar estes três pontos",action:begin).buttonStyle(.borderedProminent).disabled(room.sourcePoints.count != 3)
        }.padding(.vertical)
    }
}

struct ScannedRoomPrompt:View {
    @ObservedObject var room:ScannedRoomWall
    let cancel:()->Void
    var body:some View {
        if room.matching || room.armed {
            HStack {
                Text(room.status).font(.caption).fixedSize(horizontal:false,vertical:true)
                Button("Cancelar",action:cancel)
            }.padding(12).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12)).padding(.horizontal)
        }
    }
}
