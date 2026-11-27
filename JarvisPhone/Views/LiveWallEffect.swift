import SwiftUI
import ARKit
import SceneKit

enum LiveWallRegion {
    static func accepts(_ points:[SIMD3<Float>],classification:Int,origin:SIMD3<Float>,normal:SIMD3<Float>)->Bool {
        guard classification==ARMeshClassification.wall.rawValue,points.count==3,
              points.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),simd_length(normal)>0.9 else { return false }
        let cross=simd_cross(points[1]-points[0],points[2]-points[0])
        guard simd_length(cross)>0.00001,abs(simd_dot(simd_normalize(cross),normal))>0.96 else { return false }
        return points.allSatisfy { abs(simd_dot($0-origin,normal))<0.06 && simd_distance($0,origin)<3.5 }
    }
}

/// The headset path reads the actual wall. It never asks for GLB calibration,
/// screen taps or a drawn rectangular mask, and never paints unclassified faces.
@MainActor final class LiveWallEffect:ObservableObject {
    @Published private(set) var armed=false
    @Published private(set) var capturing=false
    @Published private(set) var busy=false
    @Published private(set) var status=""
    private let view:ARSCNView
    private var meshes:[UUID:ARMeshAnchor]=[:]
    private var root:SCNNode?
    private var anchor:ARAnchor?
    private var depthNodes:[SCNNode]=[]
    private var style="white"
    private var trackingGood=false
    private var completed=false
    private var gesture=SpatialAimSelection()
    private var ticket=UUID()
    var onFeedback:((String)->Void)?
    var onSurface:((ARRaycastResult,[ARMeshAnchor])->Bool)?
    init(view:ARSCNView) { self.view=view }
    func beginCalibration() {
        ticket=UUID();meshes=[:];completed=false;capturing=true;armed=false;busy=false;gesture.reset()
        status="Lendo o ambiente por oito segundos. Olhe devagar para o piso e as paredes."
    }
    func arm(_ style:String) {
        self.style=style=="brick" ? "brick" : "white";armed=true;busy=false
        if completed,!meshes.isEmpty {
            capturing=false;gesture.reset();status="Ambiente já lido. Aponte para a parede por dois segundos.";return
        }
        completed=false;capturing=true
        ticket=UUID();meshes=[:];gesture.reset()
        status="Olhe devagar para a parede. Leitura automática por oito segundos; depois aponte por dois segundos."
    }
    func remember(_ mesh:ARMeshAnchor) {
        guard capturing || meshes[mesh.identifier] != nil,meshes[mesh.identifier] != nil || meshes.count<64 else { return }
        meshes[mesh.identifier]=mesh
    }
    func finishCapture() {
        capturing=false;completed=true
        status=meshes.isEmpty ? "Leitura encerrada sem parede confirmada. Diga calibrar ambiente para repetir, com câmera e LiDAR livres." : armed ? "Aponte o indicador para a parede por dois segundos. Não precisa tocar no celular." : "Leitura encerrada. O catálogo está pronto para gestos e efeitos."
        onFeedback?(status)
    }
    private func surface(_ point:CGPoint)->ARRaycastResult? {
        guard let query=view.raycastQuery(from:point,allowing:.existingPlaneGeometry,alignment:.vertical) else { return nil }
        return view.session.raycast(query).first { result in
            guard let plane=result.anchor as? ARPlaneAnchor else { return false }
            return plane.classification == .wall || plane.classification == .none
        }
    }
    func hand(_ sample:SpatialHandSample?)->Double {
        guard armed,!capturing,!busy else { gesture.reset();return 0 }
        guard let sample,sample.pointing,let hit=surface(sample.point),let id=hit.anchor?.identifier else { gesture.reset();return 0 }
        if gesture.update(target:id.uuidString,point:sample.point,pointing:true,time:sample.time) != nil { apply(hit) }
        return gesture.progress
    }
    @discardableResult func tap(_ point:CGPoint)->Bool {
        guard armed else { return false }
        if !capturing,!busy,let hit=surface(point) { apply(hit) }
        return true
    }
    private func apply(_ hit:ARRaycastResult) {
        guard !meshes.isEmpty,let plane=hit.anchor as? ARPlaneAnchor,let frame=view.session.currentFrame else { return }
        if let onSurface {
            if onSurface(hit,Array(meshes.values)) { armed=false;self.onSurface=nil;gesture.reset() }
            return
        }
        let p=hit.worldTransform.columns.3,origin=SIMD3(p.x,p.y,p.z)
        var normal=simd_normalize(SIMD3(plane.transform.columns.1.x,plane.transform.columns.1.y,plane.transform.columns.1.z))
        let camera=frame.camera.transform.columns.3
        if simd_dot(SIMD3(camera.x,camera.y,camera.z)-origin,normal)<0 { normal = -normal }
        let right=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),normal))
        let pose=simd_float4x4(SIMD4(right,0),SIMD4(0,1,0,0),SIMD4(normal,0),SIMD4(origin,1))
        let values=Array(meshes.values),generation=ticket
        busy=true;status="Aplicando somente faces reconhecidas como parede…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let patch=Self.extract(values,origin:origin,normal:normal,pose:pose)
            let depths=values.compactMap { mesh -> SCNNode? in
                guard let geometry=WallARController.occlusionGeometry(mesh.geometry) else { return nil }
                let node=SCNNode(geometry:geometry);node.simdTransform=mesh.transform;node.renderingOrder = -100;node.categoryBitMask=2;return node
            }
            Task { @MainActor [weak self] in
                guard let self,self.ticket==generation else { return };self.busy=false
                guard let patch else {
                    self.status="Essa região não foi confirmada como parede. Olhe outro trecho ou repita testar parede.";self.onFeedback?(self.status);return
                }
                self.removePaint()
                patch.materials=[WallMaterials.effect(self.style)]
                let node=SCNNode(geometry:patch);node.simdTransform=pose;node.simdPosition+=normal*0.012
                let anchor=ARAnchor(name:"JarvisLiveWall",transform:node.simdTransform)
                node.categoryBitMask=1;node.isHidden = !self.trackingGood;self.root=node;self.anchor=anchor
                self.view.scene.rootNode.addChildNode(node);self.view.session.add(anchor:anchor)
                self.depthNodes=depths
                for depth in depths { depth.simdTransform=simd_inverse(node.simdTransform)*depth.simdTransform;node.addChildNode(depth) }
                self.armed=false;self.status="Efeito fixado. Faces classificadas como portas, janelas ou incertas ficaram fora."
                self.onFeedback?(self.status)
            }
        }
    }
    nonisolated static func extract(_ meshes:[ARMeshAnchor],origin:SIMD3<Float>,normal:SIMD3<Float>,pose:simd_float4x4)->SCNGeometry? {
        var vertices:[SCNVector3]=[],uv:[CGPoint]=[]
        let inverse=simd_inverse(pose)
        for anchor in meshes {
            if vertices.count>=180000 { break }
            let g=anchor.geometry
            guard let classes=g.classification,g.faces.indexCountPerPrimitive==3 else { continue }
            for face in 0..<g.faces.count {
                let kind=Int(classes.buffer.contents().advanced(by:classes.offset+face*classes.stride).load(as:UInt8.self))
                guard kind==ARMeshClassification.wall.rawValue else { continue }
                var world:[SIMD3<Float>]=[]
                for corner in 0..<3 {
                    let indexPointer=g.faces.buffer.contents().advanced(by:(face*3+corner)*g.faces.bytesPerIndex)
                    let i=g.faces.bytesPerIndex==2 ? Int(indexPointer.load(as:UInt16.self)) : Int(indexPointer.load(as:UInt32.self))
                    guard i<g.vertices.count else { continue }
                    let ptr=g.vertices.buffer.contents().advanced(by:g.vertices.offset+i*g.vertices.stride)
                    let p=anchor.transform*SIMD4(ptr.load(as:Float.self),ptr.advanced(by:4).load(as:Float.self),ptr.advanced(by:8).load(as:Float.self),1)
                    world.append(SIMD3(p.x,p.y,p.z))
                }
                guard LiveWallRegion.accepts(world,classification:kind,origin:origin,normal:normal) else { continue }
                for p in world { let local=inverse*SIMD4(p,1);vertices.append(SCNVector3(local.x,local.y,local.z));uv.append(CGPoint(x:CGFloat(local.x),y:CGFloat(local.y))) }
                if vertices.count>=180000 { break }
            }
        }
        guard vertices.count>=30 else { return nil }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:Array(repeating:SCNVector3(0,0,1),count:vertices.count)),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:Array(0..<Int32(vertices.count)),primitiveType:.triangles)])
    }
    func update(_ updated:ARAnchor) { if updated.identifier==anchor?.identifier { anchor=updated;root?.simdTransform=updated.transform } }
    func setTracking(_ good:Bool) { guard trackingGood != good else { return };trackingGood=good;root?.isHidden = !good }
    func cancel() { onSurface=nil;if capturing { completed=false };ticket=UUID();armed=false;capturing=false;busy=false;gesture.reset() }
    func removePaint() {
        if let anchor { view.session.remove(anchor:anchor) };anchor=nil
        root?.removeFromParentNode();root=nil;depthNodes.forEach{$0.removeFromParentNode()};depthNodes=[]
    }
    func clear() { cancel();removePaint();meshes=[:];completed=false }
}

struct LiveWallPrompt:View {
    @ObservedObject var wall:LiveWallEffect
    var body:some View { if wall.armed { Text(wall.status).font(.caption).padding(10).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12)).padding(.horizontal) } }
}
