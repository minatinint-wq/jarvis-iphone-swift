import SwiftUI
import ARKit
import SceneKit
import CryptoKit

struct ScannedRoomManifest:Decodable {
    struct Plane:Decodable { let id:Int;let kind:String;let normal:[Float];let center:[Float];let indices:String }
    struct File:Decodable { let file:String;let bytes:Int;let sha256:String }
    let sourceSHA256:String;let mesh:String;let texture:String;let previewIndices:String;let facePlanes:String
    let floorY:Float;let lower:[Float];let upper:[Float];let planes:[Plane];let files:[File]
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
        guard armed,tracking,let root,let faces,let m=manifest else { return false }
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
        guard let root,let faces,let m=manifest,
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
        root=node;view.scene.rootNode.addChildNode(node);aligned=true;node.isHidden = !tracking
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
                prop.contentsTransform=SCNMatrix4MakeScale(1/3,1/3,1)
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
        return SpatialScannedRoomRecord(anchor:anchor.identifier,transform:SpatialArchive.values(anchor.transform),sourceSHA256:m.sourceSHA256,plane:chosen,style:style)
    }
    @discardableResult func restore(_ saved:SpatialScannedRoomRecord,anchor:ARAnchor)->Bool {
        guard prepare(),manifest?.sourceSHA256==saved.sourceSHA256 else { return false }
        clear();style=saved.style;install(anchor);if let id=saved.plane { paint(id) };return true
    }
    func clear(preserveAnchor:Bool=false) {
        if !preserveAnchor,let anchor { view.session.remove(anchor:anchor) }
        root?.removeFromParentNode();root=nil;patch=nil;anchor=nil;chosen=nil;aligned=false;armed=false
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
