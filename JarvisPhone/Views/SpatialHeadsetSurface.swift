import UIKit
import ARKit
import SceneKit
import MetalKit
import CoreVideo

/// Each eye receives the entire same camera + world composite, never half of it.
/// This remains monoscopic passthrough; optical lens calibration is separate.
enum SpatialEyeLayout {
    static func frames(size:CGSize,gap:CGFloat=24)->[CGRect] {
        let gutter=min(gap,max(0,size.width/5)),width=max(1,floor((size.width-gutter)/2))
        return [CGRect(x:0,y:0,width:width,height:size.height),CGRect(x:size.width-width,y:0,width:width,height:size.height)]
    }
}

/// Composes one complete camera image and one SceneKit render on the GPU, then
/// repeats that same composite in two explicit, clipped viewports.
@MainActor final class SpatialEyeCompositor {
    let device:MTLDevice
    let queue:MTLCommandQueue
    let renderer:SCNRenderer
    let camera=SCNNode()
    private let pipeline:MTLRenderPipelineState
    private var cache:CVMetalTextureCache?
    private var world:MTLTexture?
    private var depth:MTLTexture?
    init(device:MTLDevice) throws {
        self.device=device
        guard let queue=device.makeCommandQueue() else { throw CocoaError(.coderInvalidValue) };self.queue=queue
        let library=try device.makeLibrary(source:Self.shader,options:nil)
        let spec=MTLRenderPipelineDescriptor();spec.vertexFunction=library.makeFunction(name:"eyeVertex");spec.fragmentFunction=library.makeFunction(name:"eyeCamera")
        spec.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:spec)
        renderer=SCNRenderer(device:device,options:nil);renderer.isPlaying=true
        camera.camera=SCNCamera();camera.camera?.zNear=0.01;camera.camera?.zFar=20
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
    }
    func renderWorld(scene:SCNScene,transform:simd_float4x4,projection:simd_float4x4,size:CGSize,time:Double,command:MTLCommandBuffer)->MTLTexture? {
        let w=max(1,Int(size.width)),h=max(1,Int(size.height))
        if world?.width != w || world?.height != h {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
            descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode = .private
            world=device.makeTexture(descriptor:descriptor)
            descriptor.pixelFormat = .depth32Float;descriptor.usage = .renderTarget
            depth=device.makeTexture(descriptor:descriptor)
        }
        guard let world,let depth else { return nil }
        camera.simdTransform=transform;camera.camera?.projectionTransform=SCNMatrix4(projection)
        scene.background.contents=UIColor.clear
        renderer.scene=scene;renderer.pointOfView=camera
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=world;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
        renderer.render(atTime:time,viewport:CGRect(x:0,y:0,width:w,height:h),commandBuffer:command,passDescriptor:pass)
        return world
    }
    @discardableResult func compose(pixels:CVPixelBuffer,displayToCamera:CGAffineTransform,world:MTLTexture,destination:MTLTexture,eyes:[CGRect],command:MTLCommandBuffer)->Bool {
        guard CVPixelBufferGetPlaneCount(pixels)==2,let cache else { return false }
        var yRef:CVMetalTexture?,uvRef:CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.r8Unorm,CVPixelBufferGetWidthOfPlane(pixels,0),CVPixelBufferGetHeightOfPlane(pixels,0),0,&yRef)==kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixels,nil,.rg8Unorm,CVPixelBufferGetWidthOfPlane(pixels,1),CVPixelBufferGetHeightOfPlane(pixels,1),1,&uvRef)==kCVReturnSuccess,
              let yRef,let uvRef,let y=CVMetalTextureGetTexture(yRef),let uv=CVMetalTextureGetTexture(uvRef) else { return false }
        var coords=[CGPoint(x:0,y:0),CGPoint(x:0,y:1),CGPoint(x:1,y:0),CGPoint(x:1,y:1)].map { p -> SIMD2<Float> in
            let q=p.applying(displayToCamera);return SIMD2(Float(q.x),Float(q.y))
        }
        let matrix=CVBufferGetAttachment(pixels,kCVImageBufferYCbCrMatrixKey,nil)?.takeUnretainedValue() as? String
        let full=CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var conversion=SIMD4<Float>(full ? 0 : 16.0/255,full ? 1 : 255.0/219,full ? 1 : 255.0/224,matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) ? 1 : 0)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=destination;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        coords.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:0) }
        encoder.setFragmentBytes(&conversion,length:MemoryLayout<SIMD4<Float>>.size,index:0)
        encoder.setFragmentTexture(y,index:0);encoder.setFragmentTexture(uv,index:1);encoder.setFragmentTexture(world,index:2)
        for eye in eyes {
            encoder.setViewport(MTLViewport(originX:Double(eye.minX),originY:Double(eye.minY),width:Double(eye.width),height:Double(eye.height),znear:0,zfar:1))
            encoder.setScissorRect(MTLScissorRect(x:Int(eye.minX),y:Int(eye.minY),width:Int(eye.width),height:Int(eye.height)))
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
        }
        encoder.endEncoding()
        command.addCompletedHandler { [pixels,yRef,uvRef] _ in withExtendedLifetime((pixels,yRef,uvRef)) {} }
        return true
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct EyeVertex { float4 position [[position]]; float2 uv; float2 cameraUV; };
    vertex EyeVertex eyeVertex(uint i [[vertex_id]],constant float2 *cameraUV [[buffer(0)]]) {
        const float2 p[4]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[4]={float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        EyeVertex o;o.position=float4(p[i],0,1);o.uv=uv[i];o.cameraUV=cameraUV[i];return o;
    }
    fragment float4 eyeCamera(EyeVertex in [[stage_in]],texture2d<float> yTex [[texture(0)]],texture2d<float> uvTex [[texture(1)]],texture2d<float> world [[texture(2)]],constant float4 &c [[buffer(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float y=(yTex.sample(s,in.cameraUV).r-c.x)*c.y;
        float2 chroma=(uvTex.sample(s,in.cameraUV).rg-0.5)*c.z;
        float3 rgb=c.w>0.5 ? float3(y+1.5748*chroma.y,y-0.187324*chroma.x-0.468124*chroma.y,y+1.8556*chroma.x) : float3(y+1.402*chroma.y,y-0.344136*chroma.x-0.714136*chroma.y,y+1.772*chroma.x);
        float4 ar=world.sample(s,in.uv);
        return float4(ar.rgb+clamp(rgb,0.0,1.0)*(1-ar.a),1);
    }
    """
}

@MainActor final class SpatialHeadsetSurface:UIView,MTKViewDelegate {
    private weak var controller:WallARController?
    private let primary:ARSCNView
    private(set) var output:MTKView?
    private(set) var compositor:SpatialEyeCompositor?
    private let leftOverlay=UIView(),rightOverlay=UIView()
    private var originalCamera:SCNNode?
    private var originalBackground:Any?
    private var headset=false
    private var viewport=CGSize.zero
    private var pendingFrame:ARFrame?
    var eyeFrames:[CGRect] { SpatialEyeLayout.frames(size:bounds.size) }
    init(controller:WallARController) {
        self.controller=controller;primary=controller.view
        super.init(frame:.zero);backgroundColor = .black;clipsToBounds=true;addSubview(primary)
        leftOverlay.isUserInteractionEnabled=false;rightOverlay.isUserInteractionEnabled=false
        leftOverlay.clipsToBounds=true;rightOverlay.clipsToBounds=true
        controller.onHeadsetFrame={ [weak self] frame in self?.render(frame) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(headset:Bool) {
        guard self.headset != headset else { return }
        if headset {
            do {
                guard let device=MTLCreateSystemDefaultDevice() else { throw CocoaError(.coderInvalidValue) }
                let compositor=try SpatialEyeCompositor(device:device)
                let output=MTKView(frame:bounds,device:device);output.colorPixelFormat = .bgra8Unorm
                output.delegate=self
                output.isPaused=true;output.enableSetNeedsDisplay=false;output.isUserInteractionEnabled=false
                originalCamera=primary.pointOfView;originalBackground=primary.scene.background.contents
                self.compositor=compositor;self.output=output;self.headset=true
                primary.isPlaying=false;primary.rendersContinuously=false;primary.isHidden=true
                primary.pointOfView=compositor.camera
                addSubview(output);addSubview(leftOverlay);addSubview(rightOverlay)
                controller?.hands.presentOverlay(in:leftOverlay);controller?.hands.mirrorOverlay(in:rightOverlay)
                addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tapHeadset(_:))))
            } catch {
                Task { @MainActor [weak controller] in controller?.setHeadset(false);controller?.notice="O visor GPU não iniciou. O modo normal foi mantido." }
                return
            }
        } else {
            self.headset=false
            controller?.hands.mirrorOverlay(in:nil);controller?.hands.presentOverlay(in:nil)
            leftOverlay.removeFromSuperview();rightOverlay.removeFromSuperview();output?.delegate=nil;output?.removeFromSuperview();output=nil;compositor=nil;pendingFrame=nil
            primary.pointOfView=originalCamera;primary.scene.background.contents=originalBackground;originalCamera=nil;originalBackground=nil
            primary.isHidden=false;primary.isPlaying=controller?.videoRunning == true;primary.rendersContinuously=primary.isPlaying
            gestureRecognizers?.forEach { removeGestureRecognizer($0) }
        }
        controller?.hands.reset();setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let eyes=eyeFrames
        primary.frame=headset ? eyes[0] : bounds
        output?.frame=bounds;leftOverlay.frame=eyes[0];rightOverlay.frame=eyes[1]
        if viewport != primary.bounds.size { viewport=primary.bounds.size;controller?.hands.reset() }
    }
    private func render(_ frame:ARFrame) {
        guard headset,controller?.videoRunning == true,let output else { return }
        pendingFrame=frame;output.draw();pendingFrame=nil
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    func draw(in output:MTKView) {
        guard let frame=pendingFrame,let compositor,let drawable=output.currentDrawable,let command=compositor.queue.makeCommandBuffer() else { return }
        let orientation=window?.windowScene?.interfaceOrientation ?? .landscapeRight
        let scaleX=CGFloat(drawable.texture.width)/max(1,bounds.width)
        let eyes=eyeFrames.map { CGRect(x:($0.minX*scaleX).rounded(),y:0,width:($0.width*scaleX).rounded(.down),height:CGFloat(drawable.texture.height)) }
        let size=CGSize(width:eyes[0].width,height:eyes[0].height)
        guard let world=compositor.renderWorld(scene:primary.scene,transform:simd_inverse(frame.camera.viewMatrix(for:orientation)),projection:frame.camera.projectionMatrix(for:orientation,viewportSize:primary.bounds.size,zNear:0.01,zFar:20),size:size,time:CACurrentMediaTime(),command:command) else { return }
        primary.pointOfView=compositor.camera
        let transform=frame.displayTransform(for:orientation,viewportSize:primary.bounds.size).inverted()
        guard compositor.compose(pixels:frame.capturedImage,displayToCamera:transform,world:world,destination:drawable.texture,eyes:eyes,command:command) else { return }
        command.present(drawable);command.commit()
    }
    @objc private func tapHeadset(_ gesture:UITapGestureRecognizer) {
        let point=gesture.location(in:self)
        for eye in eyeFrames where eye.contains(point) { controller?.tap(at:CGPoint(x:point.x-eye.minX,y:point.y-eye.minY));return }
    }
}
