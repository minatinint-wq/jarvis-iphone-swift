import ARKit
import SceneKit
import Metal
import UIKit

/// A separate 3D world is rendered through a wall-sized, irregular aperture.
/// Forest geometry cannot leak across the real wall because it is never added
/// to the AR scene. The off-axis projection supplies viewpoint-dependent depth.
@MainActor final class SpatialPortalRenderer {
    let scene=SCNScene()
    let camera=SCNNode()
    let material=SCNMaterial()
    private let renderer:SCNRenderer
    private let queue:MTLCommandQueue
    private var textures:[MTLTexture]=[]
    private let depth:MTLTexture
    private var displayed = -1
    private var cursor=0
    private var busy=false
    private var lastTime = -Double.infinity
    private var generation=UUID()
    let size=CGSize(width:576,height:768)
    init?(device:MTLDevice?) {
        guard let device,let queue=device.makeCommandQueue() else { return nil }
        self.queue=queue;renderer=SCNRenderer(device:device,options:nil)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:576,height:768,mipmapped:false)
        descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode = .private
        for _ in 0..<3 { guard let texture=device.makeTexture(descriptor:descriptor) else { return nil };textures.append(texture) }
        let z=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:576,height:768,mipmapped:false)
        z.usage = .renderTarget;z.storageMode = .private
        guard let depth=device.makeTexture(descriptor:z) else { return nil };self.depth=depth
        camera.camera=SCNCamera();camera.camera?.zNear=0.04;camera.camera?.zFar=40
        scene.rootNode.addChildNode(camera);Self.populate(scene)
        renderer.scene=scene;renderer.pointOfView=camera
        material.lightingModel = .constant;material.isDoubleSided=false
        material.diffuse.contents=UIColor(red:0.06,green:0.13,blue:0.10,alpha:1)
        material.diffuse.contentsTransform=SCNMatrix4MakeScale(1,-1,1)
        material.diffuse.wrapT = .repeat
        material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear
    }
    static func populate(_ scene:SCNScene) {
        scene.background.contents=UIColor(red:0.34,green:0.48,blue:0.43,alpha:1)
        scene.fogColor=UIColor(red:0.34,green:0.48,blue:0.43,alpha:1);scene.fogStartDistance=5;scene.fogEndDistance=17
        let sun=SCNNode();sun.light=SCNLight();sun.light?.type = .directional;sun.light?.intensity=1300
        sun.light?.color=UIColor(red:1,green:0.91,blue:0.73,alpha:1);sun.eulerAngles=SCNVector3(-0.8,-0.4,0);scene.rootNode.addChildNode(sun)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=450
        ambient.light?.color=UIColor(red:0.63,green:0.75,blue:0.70,alpha:1);scene.rootNode.addChildNode(ambient)
        let ground=SCNNode(geometry:SCNPlane(width:24,height:24));ground.eulerAngles.x = -.pi/2;ground.position=SCNVector3(0,-0.65,-9)
        let moss=SCNMaterial();moss.lightingModel = .physicallyBased;moss.roughness.contents=0.95
        moss.diffuse.contents=(UIImage(named:"Spatial_mossrock_Color.jpg") as Any?) ?? UIColor(red:0.19,green:0.25,blue:0.12,alpha:1) as Any
        moss.diffuse.contentsTransform=SCNMatrix4MakeScale(10,10,1);moss.diffuse.wrapS = .repeat;moss.diffuse.wrapT = .repeat
        ground.geometry?.materials=[moss];scene.rootNode.addChildNode(ground)
        // Finished, textured local models; loaded once, never downloaded per frame.
        func model(_ id:String,_ size:Float,_ position:SCNVector3,_ rotation:Float=0) {
            guard let node=try? SpatialAssets.load(id) else { return }
            let bounds=node.boundingBox,extent=max(bounds.max.x-bounds.min.x,bounds.max.y-bounds.min.y,bounds.max.z-bounds.min.z)
            guard extent>0 else { return }
            let k=size/extent;node.simdScale=SIMD3(repeating:k)
            node.position=SCNVector3(position.x,position.y-bounds.min.y*k,position.z);node.eulerAngles.y=rotation
            scene.rootNode.addChildNode(node)
        }
        for i in 0..<22 {
            let z = -0.55-Float(i/4)*1.05,x=Float(i%4)*1.05-1.55
            model("fern",0.65+Float(i%3)*0.17,SCNVector3(x,-0.65,z),Float(i)*1.71)
        }
        for i in 0..<7 { model("mossrock",0.45+Float(i%3)*0.18,SCNVector3(Float(i%3)-0.85,-0.65,-1.3-Float(i)*0.69),Float(i)) }
        for i in 0..<14 {
            let x:Float=(i%2==0 ? -1 : 1)*(1.2+Float(i%4)*0.45),z:Float = -1.4-Float(i/2)*1.5
            let trunk=SCNNode(geometry:SCNCylinder(radius:CGFloat(0.10+Float(i%3)*0.035),height:7))
            trunk.position=SCNVector3(x,2.85,z);trunk.geometry?.materials=[moss.copy() as! SCNMaterial]
            trunk.geometry?.firstMaterial?.multiply.contents=UIColor(red:0.45,green:0.36,blue:0.24,alpha:1);scene.rootNode.addChildNode(trunk)
            let crown=SCNNode(geometry:SCNSphere(radius:1.5));crown.scale=SCNVector3(1,0.55,1);crown.position=SCNVector3(x,3.25,z)
            let leaf=SCNMaterial();leaf.diffuse.contents=UIColor(red:0.11,green:0.24,blue:0.10,alpha:1);leaf.roughness.contents=1;crown.geometry?.materials=[leaf];scene.rootNode.addChildNode(crown)
        }
        model("animated_fox",0.40,SCNVector3(0.13,-0.65,-2.8))
        for i in 0..<10 {
            let mote=SCNNode(geometry:SCNSphere(radius:0.009));mote.position=SCNVector3(sin(Float(i)*2.7)*1.2,-0.2+Float(i%4)*0.22,-0.8-Float(i)*0.4)
            let glow=SCNMaterial();glow.lightingModel = .constant;glow.diffuse.contents=UIColor(red:0.85,green:1,blue:0.5,alpha:1);mote.geometry?.materials=[glow]
            mote.runAction(.repeatForever(.sequence([.moveBy(x:0.06,y:0.08,z:0,duration:2+Double(i%3)),.moveBy(x:-0.06,y:-0.08,z:0,duration:2+Double(i%3))])))
            scene.rootNode.addChildNode(mote)
        }
    }
    func frame(eye:SIMD3<Float>,width:Float,height:Float,time:Double) {
        guard !busy,time-lastTime>=1/30,let projection=SpatialPortalMath.projection(eye:eye,width:width,height:height),let buffer=queue.makeCommandBuffer() else { return }
        busy=true;lastTime=time;cursor=(cursor+1)%textures.count
        if cursor==displayed { cursor=(cursor+1)%textures.count }
        let slot=cursor,ticket=generation
        camera.simdPosition=eye;camera.camera?.projectionTransform=SCNMatrix4(projection)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=textures[slot]
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.2,0.15,1)
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
        renderer.render(atTime:time,viewport:CGRect(origin:.zero,size:size),commandBuffer:buffer,passDescriptor:pass)
        buffer.addCompletedHandler { [weak self] command in
            let succeeded=command.status == .completed
            Task { @MainActor [weak self] in
                guard let self,self.generation==ticket else { return };self.busy=false
                if succeeded { self.displayed=slot;self.material.diffuse.contents=self.textures[slot] }
            }
        }
        buffer.commit()
    }
}

@MainActor final class SpatialWallPortal {
    private let view:ARSCNView
    private(set) var root:SCNNode?
    private var anchor:ARAnchor?
    private var renderer:SpatialPortalRenderer?
    private var record:SpatialPortalRecord?
    private var tracking=false
    var onChange:(()->Void)?
    var onFeedback:((String)->Void)?
    init(view:ARSCNView) { self.view=view }
    static func aperture(width:Float,height:Float)->SCNGeometry {
        let edge=SpatialPortalMath.outline(width:width,height:height)
        let vertices=[SCNVector3(0,0,0)]+edge.map{SCNVector3($0.x,$0.y,0)}
        let uv=[CGPoint(x:0.5,y:0.5)]+edge.map{CGPoint(x:CGFloat($0.x/width+0.5),y:CGFloat($0.y/height+0.5))}
        let indices=(0..<edge.count).flatMap { [Int32(0),Int32($0+1),Int32(($0+1)%edge.count+1)] }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    }
    func place(_ hit:ARRaycastResult,meshes:[ARMeshAnchor])->Bool {
        guard let plane=hit.anchor as? ARPlaneAnchor,let frame=view.session.currentFrame else { return false }
        let origin=SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z)
        var normal=simd_normalize(SIMD3(plane.transform.columns.1.x,plane.transform.columns.1.y,plane.transform.columns.1.z))
        guard abs(normal.y)<0.15 else { onFeedback?("Escolha uma parede vertical.");return false }
        let eye=frame.camera.transform.columns.3
        if simd_dot(SIMD3(eye.x,eye.y,eye.z)-origin,normal)<0 { normal = -normal }
        let right=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),normal))
        let pose=simd_float4x4(SIMD4(right,0),SIMD4(0,1,0,0),SIMD4(normal,0),SIMD4(origin+normal*0.025,1))
        guard let wall=LiveWallEffect.extract(meshes,origin:origin,normal:normal,pose:pose),let source=wall.sources(for:.vertex).first else { return false }
        let points:[SIMD2<Float>]=source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { i in
                let offset=source.dataOffset+i*source.dataStride
                return SIMD2(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self))
            }
        }
        let width:Float=0.65,height:Float=0.85
        guard SpatialPortalMath.fitsWall(width:width,height:height,triangles:points) else {
            onFeedback?("Esse trecho não tem parede suficiente confirmada. Aponte para uma área livre, longe da porta e dos móveis.");return false
        }
        guard let renderer=SpatialPortalRenderer(device:view.device) else { onFeedback?("O renderizador do portal não iniciou.");return false }
        clear(recordChange:false)
        let anchor=ARAnchor(name:"JarvisWallPortal",transform:pose)
        self.renderer=renderer;self.anchor=anchor;record=SpatialPortalRecord(anchor:anchor.identifier,width:width,height:height)
        build(pose:pose,animate:true);view.session.add(anchor:anchor);onChange?()
        onFeedback?("Portal fixado na parede. Pode mudar de lugar para testar a profundidade. Diga fechar portal para remover.")
        return true
    }
    private func build(pose:simd_float4x4,animate:Bool) {
        guard let record,let renderer else { return }
        let root=SCNNode();root.simdTransform=pose;root.isHidden = !tracking
        let hole=SCNNode(geometry:Self.aperture(width:record.width,height:record.height));hole.geometry?.materials=[renderer.material];root.addChildNode(hole)
        let edge=SpatialPortalMath.outline(width:record.width,height:record.height)
        for i in 0..<edge.count {
            let a=edge[i],b=edge[(i+1)%edge.count],delta=b-a
            let chunk=SCNNode(geometry:SCNBox(width:CGFloat(simd_length(delta)+0.012),height:0.045, length:0.065,chamferRadius:0.008))
            chunk.position=SCNVector3((a.x+b.x)/2,(a.y+b.y)/2,0.018);chunk.eulerAngles.z=atan2(delta.y,delta.x)
            chunk.geometry?.materials=[WallMaterials.effect("brick")];root.addChildNode(chunk)
            if animate,i%2==0 {
                let debris=chunk.clone();debris.position.z+=0.04;debris.scale=SCNVector3(0.7,0.8,0.7);root.addChildNode(debris)
                debris.runAction(.sequence([.group([.moveBy(x:CGFloat(a.x)*0.4,y:-0.6,z:0.3,duration:0.9),.rotateBy(x:1.3,y:0.8,z:0.5,duration:0.9),.sequence([.wait(duration:0.4),.fadeOut(duration:0.5)])]),.removeFromParentNode()]))
            }
        }
        if animate { hole.scale=SCNVector3(0.01,0.01,1);hole.runAction(.scale(to:1,duration:0.7)) }
        self.root=root;view.scene.rootNode.addChildNode(root)
    }
    func snapshot()->SpatialPortalRecord? { record }
    func restore(_ saved:SpatialPortalRecord,anchor:ARAnchor) {
        guard saved.valid,saved.anchor==anchor.identifier,anchor.name=="JarvisWallPortal",let renderer=SpatialPortalRenderer(device:view.device) else { return }
        clear(recordChange:false);record=saved;self.anchor=anchor;self.renderer=renderer;build(pose:anchor.transform,animate:false)
    }
    func update(_ updated:ARAnchor) {
        guard updated.identifier==anchor?.identifier else { return };anchor=updated;root?.simdTransform=updated.transform
    }
    func frame(_ frame:ARFrame,stable:Bool) {
        tracking=stable
        guard let root,let record else { return }
        let local=simd_inverse(root.simdTransform)*frame.camera.transform.columns.3,eye=SIMD3(local.x,local.y,local.z)
        root.isHidden = !stable || eye.z<=0.08
        if !root.isHidden { renderer?.frame(eye:eye,width:record.width,height:record.height,time:frame.timestamp) }
    }
    func clear(recordChange:Bool=true,preserveAnchor:Bool=false) {
        if !preserveAnchor,let anchor { view.session.remove(anchor:anchor) }
        anchor=nil;root?.removeFromParentNode();root=nil;record=nil;renderer=nil
        if recordChange { onChange?() }
    }
}
