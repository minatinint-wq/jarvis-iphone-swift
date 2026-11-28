import UIKit
import ARKit
import SceneKit
import MetalKit
import CoreVideo
import AVFoundation
import CoreMedia

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
final class SpatialEyeCompositor {
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

@MainActor final class SpatialHeadsetSurface:UIView {
    private weak var controller:WallARController?
    private let primary:ARSCNView
    private(set) var output:SpatialMetalSurface?
    private(set) var eyes:[SpatialHeadsetEye]=[]
    private let stereoHost=UIView()
    private var worker:SpatialHeadsetWorker?
    private let renderQueue=DispatchQueue(label:"jarvis.vr.render",qos:.userInteractive)
    private let leftOverlay=UIView(),rightOverlay=UIView()
    private let inputCamera=SCNNode()
    private var originalCamera:SCNNode?
    private var originalBackground:Any?
    private weak var originalDelegate:ARSCNViewDelegate?
    private var headset=false
    private var viewport=CGSize.zero
    private var busy=false
    private var generation=0
    private var lastPresented = -Double.infinity
    var compositor:SpatialEyeCompositor? { worker?.compositor }
    var eyeFrames:[CGRect] { SpatialEyeLayout.frames(size:bounds.size) }
    init(controller:WallARController) {
        self.controller=controller;primary=controller.view
        super.init(frame:.zero);backgroundColor = .black;clipsToBounds=true;addSubview(primary)
        primary.clipsToBounds=true
        stereoHost.backgroundColor = .black;stereoHost.clipsToBounds=true
        inputCamera.camera=SCNCamera();inputCamera.camera?.categoryBitMask=0
        leftOverlay.isUserInteractionEnabled=false;rightOverlay.isUserInteractionEnabled=false
        leftOverlay.clipsToBounds=true;rightOverlay.clipsToBounds=true
        controller.onHeadsetFrame={ [weak self] frame in self?.render(frame) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(headset:Bool) {
        guard self.headset != headset else { return }
        generation+=1;busy=false
        if headset {
            do {
                guard let device=MTLCreateSystemDefaultDevice() else { throw CocoaError(.coderInvalidValue) }
                let compositor=try SpatialEyeCompositor(device:device)
                let eyes=[SpatialHeadsetEye(device:device),SpatialHeadsetEye(device:device)]
                self.eyes=eyes
                originalCamera=primary.pointOfView;originalBackground=primary.scene.background.contents;originalDelegate=primary.delegate
                compositor.renderer.delegate=originalDelegate
                worker=SpatialHeadsetWorker(compositor:compositor,layers:eyes.map{$0.world.metalLayer},scene:primary.scene)
                self.output=eyes[0].world;self.headset=true;lastPresented = -.infinity
                // Keep the ARKit view alive underneath. It renders no world
                // geometry; the compositor owns its own independent camera.
                primary.isHidden=false;primary.isPlaying=controller?.videoRunning == true;primary.rendersContinuously=primary.isPlaying
                primary.pointOfView=inputCamera;primary.delegate=nil
                addSubview(stereoHost)
                for eye in eyes { stereoHost.addSubview(eye) }
                eyes[0].addSubview(leftOverlay);eyes[1].addSubview(rightOverlay)
                controller?.hands.presentOverlay(in:leftOverlay);controller?.hands.mirrorOverlay(in:rightOverlay)
                addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tapHeadset(_:))))
            } catch {
                Task { @MainActor [weak controller] in controller?.setHeadset(false);controller?.notice="O visor GPU não iniciou. O modo normal foi mantido." }
                return
            }
        } else {
            self.headset=false
            controller?.hands.mirrorOverlay(in:nil);controller?.hands.presentOverlay(in:nil)
            leftOverlay.removeFromSuperview();rightOverlay.removeFromSuperview()
            for eye in eyes { eye.video.sampleBufferRenderer.flush(removingDisplayedImage:true,completionHandler:nil);eye.removeFromSuperview() }
            stereoHost.removeFromSuperview();eyes=[];output=nil;worker=nil
            primary.pointOfView=originalCamera;primary.scene.background.contents=originalBackground;primary.delegate=originalDelegate
            originalCamera=nil;originalBackground=nil;originalDelegate=nil
            primary.isHidden=false;primary.isPlaying=controller?.videoRunning == true;primary.rendersContinuously=primary.isPlaying
            gestureRecognizers?.forEach { removeGestureRecognizer($0) }
        }
        controller?.hands.reset();setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let eyes=eyeFrames
        primary.frame=headset ? eyes[0] : bounds
        stereoHost.frame=bounds
        for (eye,frame) in zip(self.eyes,eyes) { eye.frame=frame;eye.layoutIfNeeded() }
        leftOverlay.frame=CGRect(origin:.zero,size:eyes[0].size);rightOverlay.frame=CGRect(origin:.zero,size:eyes[1].size)
        if viewport != primary.bounds.size { viewport=primary.bounds.size;controller?.hands.reset() }
    }
    private func render(_ frame:ARFrame) {
        guard headset,controller?.videoRunning == true,let worker,bounds.width>0,bounds.height>0 else { return }
        let orientation=window?.windowScene?.interfaceOrientation ?? .landscapeRight
        // Same physical, clipped video layers as Holo Comandos. Camera delivery
        // does not wait for SceneKit, drawable acquisition or world localization.
        displayCamera(frame.capturedImage,orientation:orientation,time:frame.timestamp)
        let transform=simd_inverse(frame.camera.viewMatrix(for:orientation))
        let projection=frame.camera.projectionMatrix(for:orientation,viewportSize:primary.bounds.size,zNear:0.01,zFar:20)
        inputCamera.simdTransform=transform;inputCamera.camera?.projectionTransform=SCNMatrix4(projection);primary.pointOfView=inputCamera
        let interval=1/Double(max(1,primary.preferredFramesPerSecond))
        guard !busy,frame.timestamp-lastPresented>=interval-0.001 else { return }
        lastPresented=frame.timestamp;busy=true
        let stamp=generation,size=bounds.size,pointSize=primary.bounds.size,eyes=eyeFrames
        let packet=SpatialHeadsetPacket(frame:frame,orientation:orientation,pointSize:pointSize,outputSize:size,eyes:eyes,transform:transform,projection:projection)
        renderQueue.async { [weak self] in
            worker.render(packet)
            Task { @MainActor [weak self] in if let self,self.generation==stamp { self.busy=false } }
        }
    }
    @discardableResult func displayCamera(_ pixels:CVPixelBuffer,orientation:UIInterfaceOrientation,time:Double)->Bool {
        guard headset,eyes.count==2 else { return false }
        var format:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels,formatDescriptionOut:&format)==noErr,let format else { return false }
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(seconds:time,preferredTimescale:600),decodeTimeStamp:.invalid)
        var sample:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels,formatDescription:format,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,let sample else { return false }
        if let array=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true),CFArrayGetCount(array)>0 {
            let dict=unsafeBitCast(CFArrayGetValueAtIndex(array,0),to:CFMutableDictionary.self)
            CFDictionarySetValue(dict,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        for eye in eyes { eye.display(sample,orientation:orientation) }
        return true
    }
    @objc private func tapHeadset(_ gesture:UITapGestureRecognizer) {
        let point=gesture.location(in:self)
        for eye in eyeFrames where eye.contains(point) { controller?.tap(at:CGPoint(x:point.x-eye.minX,y:point.y-eye.minY));return }
    }
}

/// Holo Comandos' two-host video layout, fed by the existing ARSession rather
/// than a second AVCaptureSession. Both eyes get the entire same sample.
@MainActor final class SpatialHeadsetEye:UIView {
    let video=AVSampleBufferDisplayLayer()
    let world=SpatialMetalSurface(frame:.zero)
    private(set) var cameraFrames=0
    private var orientation:UIInterfaceOrientation = .landscapeRight
    init(device:MTLDevice) {
        super.init(frame:.zero);clipsToBounds=true;backgroundColor = .black
        video.videoGravity = .resizeAspectFill;layer.addSublayer(video)
        world.isOpaque=false;world.backgroundColor = .clear
        let output=world.metalLayer;output.isOpaque=false;output.device=device
        output.pixelFormat = .bgra8Unorm;output.framebufferOnly=false
        output.maximumDrawableCount=2;output.allowsNextDrawableTimeout=true
        addSubview(world)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews();world.frame=bounds
        world.metalLayer.drawableSize=CGSize(width:bounds.width*world.contentScaleFactor,height:bounds.height*world.contentScaleFactor)
        let portrait=orientation == .portrait || orientation == .portraitUpsideDown
        let angle:CGFloat=orientation == .landscapeLeft ? .pi : orientation == .portrait ? .pi/2 : orientation == .portraitUpsideDown ? -.pi/2 : 0
        CATransaction.begin();CATransaction.setDisableActions(true)
        video.bounds=CGRect(origin:.zero,size:portrait ? CGSize(width:bounds.height,height:bounds.width) : bounds.size)
        video.position=CGPoint(x:bounds.midX,y:bounds.midY);video.setAffineTransform(CGAffineTransform(rotationAngle:angle))
        CATransaction.commit()
    }
    func display(_ sample:CMSampleBuffer,orientation:UIInterfaceOrientation) {
        if self.orientation != orientation { self.orientation=orientation;setNeedsLayout();layoutIfNeeded() }
        let renderer=video.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(removingDisplayedImage:true,completionHandler:nil) }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample);cameraFrames+=1 }
    }
}

final class SpatialMetalSurface:UIView {
    override class var layerClass:AnyClass { CAMetalLayer.self }
    var metalLayer:CAMetalLayer { layer as! CAMetalLayer }
    override init(frame:CGRect) { super.init(frame:frame);contentScaleFactor=UIScreen.main.scale;isUserInteractionEnabled=false;backgroundColor = .black }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private struct SpatialHeadsetPacket:@unchecked Sendable {
    let frame:ARFrame
    let orientation:UIInterfaceOrientation
    let pointSize:CGSize
    let outputSize:CGSize
    let eyes:[CGRect]
    let transform:simd_float4x4
    let projection:simd_float4x4
}
private final class SpatialHeadsetWorker:@unchecked Sendable {
    let compositor:SpatialEyeCompositor
    let layers:[CAMetalLayer]
    let scene:SCNScene
    init(compositor:SpatialEyeCompositor,layers:[CAMetalLayer],scene:SCNScene) { self.compositor=compositor;self.layers=layers;self.scene=scene }
    func render(_ packet:SpatialHeadsetPacket) {
        autoreleasepool {
            // Drawable waits and shader preparation must never block ARKit,
            // hand input, voice or the main run loop. Only one packet is queued.
            let drawables=layers.compactMap{$0.nextDrawable()}
            guard drawables.count==2,let first=drawables.first,let command=compositor.queue.makeCommandBuffer() else { return }
            let size=CGSize(width:first.texture.width,height:first.texture.height)
            guard let world=compositor.renderWorld(scene:scene,transform:packet.transform,projection:packet.projection,size:size,time:CACurrentMediaTime(),command:command),let blit=command.makeBlitCommandEncoder() else { return }
            for drawable in drawables {
                let size=MTLSize(width:min(world.width,drawable.texture.width),height:min(world.height,drawable.texture.height),depth:1)
                blit.copy(from:world,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:size,to:drawable.texture,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
            }
            blit.endEncoding()
            for drawable in drawables { command.present(drawable) };command.commit()
        }
    }
}
