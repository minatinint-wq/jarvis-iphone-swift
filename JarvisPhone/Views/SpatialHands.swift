import ARKit
import Vision
import CoreImage
import UIKit

struct SpatialHandSample {
    let point:CGPoint
    let ratio:Double
    let world:SIMD3<Float>?
    let time:Double
}

/// Native adapter for the iPhone: uses ARKit's existing camera, never opens a
/// second capture session. Hand-OSC-Lab inspired the temporal input design;
/// its WebXR 25-joint runtime is not shipped as an iPhone hand tracker.
@MainActor final class SpatialHands {
    private let queue=DispatchQueue(label:"jarvis.spatial.hands",qos:.userInitiated)
    private var busy=false
    private var lastFrame:Double = -.infinity
    private var generation=0
    private var wasEnabled=false
    private var smoothed:CGPoint?
    private var lastSeen:Double=0
    private let cursor=UIView(frame:CGRect(x:0,y:0,width:24,height:24))
    private let bones=CAShapeLayer()
    var onSample:((SpatialHandSample?)->Void)?
    var onQuality:((String)->Void)?
    private var quality=""
    init(view:ARSCNView) {
        cursor.isUserInteractionEnabled=false;cursor.layer.cornerRadius=12;cursor.layer.borderWidth=2;cursor.layer.borderColor=UIColor.cyan.cgColor
        cursor.backgroundColor=UIColor.cyan.withAlphaComponent(0.18);cursor.isHidden=true;view.addSubview(cursor)
        bones.strokeColor=UIColor.cyan.withAlphaComponent(0.65).cgColor;bones.fillColor=UIColor.clear.cgColor;bones.lineWidth=1.3
        view.layer.addSublayer(bones)
    }
    func reset() { generation+=1;cursor.isHidden=true;bones.path=nil;smoothed=nil;onSample?(nil) }
    private func report(_ text:String) { if text != quality { quality=text;onQuality?(text) } }
    func update(_ frame:ARFrame,view:ARSCNView,enabled:Bool) {
        guard enabled else { if wasEnabled { reset() };wasEnabled=false;return };wasEnabled=true
        let interval=ProcessInfo.processInfo.thermalState == .serious ? 0.125 : 1.0/15
        guard !busy,frame.timestamp-lastFrame>=interval else { return }
        busy=true;lastFrame=frame.timestamp
        let ticket=generation,stamp=frame.timestamp,size=view.bounds.size
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform=frame.displayTransform(for:orientation,viewportSize:size)
        let imageOrientation:CGImagePropertyOrientation=orientation == .landscapeLeft ? .down : orientation == .landscapeRight ? .up : orientation == .portraitUpsideDown ? .left : .right
        let pixels=frame.capturedImage,camera=frame.camera.transform,intrinsics=frame.camera.intrinsics,resolution=frame.camera.imageResolution
        let depth=frame.smoothedSceneDepth
        queue.async {
            let luminance=Self.luminance(pixels)
            var image=CIImage(cvPixelBuffer:pixels)
            if luminance<0.25 {
                let gain=min(1.0,max(0,log2(0.25/max(0.03,luminance))))
                image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:gain])
                    .applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":0.015,"inputSharpness":0.3])
            }
            let request=VNDetectHumanHandPoseRequest();request.maximumHandCount=1
            var positions:[CGPoint?]=[];var ratio:Double?;var world:SIMD3<Float>?
            do {
                try VNImageRequestHandler(ciImage:image,orientation:imageOrientation).perform([request])
                if luminance>=0.045,let hand=request.results?.first {
                    let keys:[VNHumanHandPoseObservation.JointName]=[.wrist,.thumbCMC,.thumbMP,.thumbIP,.thumbTip,.indexMCP,.indexPIP,.indexDIP,.indexTip,.middleMCP,.middlePIP,.middleDIP,.middleTip,.ringMCP,.ringPIP,.ringDIP,.ringTip,.littleMCP,.littlePIP,.littleDIP,.littleTip]
                    let joints=try hand.recognizedPoints(.all)
                    let raw=keys.map { key -> CGPoint? in
                        guard let p=joints[key],p.confidence>=0.55 else { return nil }
                        let upright=CGPoint(x:p.location.x,y:1-p.location.y)
                        switch imageOrientation {
                        case .right:return CGPoint(x:upright.y,y:1-upright.x)
                        case .left:return CGPoint(x:1-upright.y,y:upright.x)
                        case .down:return CGPoint(x:1-upright.x,y:1-upright.y)
                        default:return upright
                        }
                    }
                    positions=raw.map { $0.map { p in let q=p.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) } }
                    if let tip=raw[8],let thumb=raw[4],let wrist=raw[0],let knuckle=raw[9] {
                        func distance(_ a:CGPoint,_ b:CGPoint)->Double { hypot((a.x-b.x)*resolution.width,(a.y-b.y)*resolution.height) }
                        let scale=distance(wrist,knuckle)
                        if scale>resolution.width*0.035 { ratio=distance(tip,thumb)/scale }
                        if let metres=Self.depth(at:tip,data:depth) {
                            let z=Float(metres),x=(Float(tip.x*resolution.width)-intrinsics.columns.2.x)/intrinsics.columns.0.x*z
                            let y = -(Float(tip.y*resolution.height)-intrinsics.columns.2.y)/intrinsics.columns.1.y*z
                            let p=camera*SIMD4<Float>(x,y,-z,1);world=SIMD3(p.x,p.y,p.z)
                        }
                    }
                }
            } catch { }
            let result=positions,amount=ratio,location=world
            Task { @MainActor [weak self] in
                guard let self else { return };self.busy=false
                guard self.generation==ticket,ProcessInfo.processInfo.systemUptime-stamp<0.35 else { return }
                guard let amount,result.count==21,let point=result[8],CGRect(origin:.zero,size:size).contains(point) else {
                    if stamp-self.lastSeen>0.18 { self.cursor.isHidden=true;self.bones.path=nil;self.smoothed=nil }
                    self.report(luminance<0.12 ? "Pouca luz: ilumine a mão. Gestos pausados quando não houver confiança." : "Mostre a mão à câmera traseira. Abra os dedos antes de clicar.")
                    self.onSample?(nil);return
                }
                let dt=max(0.001,min(0.15,stamp-self.lastSeen)),alpha=1-exp(-dt/0.045)
                let p=self.smoothed.map { CGPoint(x:$0.x+(point.x-$0.x)*alpha,y:$0.y+(point.y-$0.y)*alpha) } ?? point
                self.smoothed=p;self.lastSeen=stamp;self.cursor.center=p;self.cursor.isHidden=false
                self.cursor.layer.borderColor=(amount<0.28 ? UIColor.orange : .cyan).cgColor
                let path=UIBezierPath()
                for chain in [[0,1,2,3,4],[0,5,6,7,8],[0,9,10,11,12],[0,13,14,15,16],[0,17,18,19,20],[5,9,13,17]] {
                    for pair in zip(chain,chain.dropFirst()) { if let a=result[pair.0],let b=result[pair.1] { path.move(to:a);path.addLine(to:b) } }
                }
                self.bones.path=path.cgPath
                self.report(luminance<0.12 ? "Compensando pouca luz · mantenha a mão visível." : "Indicador aponta · pinça clica · segure para arrastar · solte para fixar.")
                self.onSample?(SpatialHandSample(point:p,ratio:amount,world:location,time:stamp))
            }
        }
    }
    nonisolated private static func luminance(_ pixels:CVPixelBuffer)->Double {
        guard CVPixelBufferGetPlaneCount(pixels)>0 else { return 0.5 }
        CVPixelBufferLockBaseAddress(pixels,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddressOfPlane(pixels,0) else { return 0.5 }
        let w=CVPixelBufferGetWidthOfPlane(pixels,0),h=CVPixelBufferGetHeightOfPlane(pixels,0),stride=CVPixelBufferGetBytesPerRowOfPlane(pixels,0)
        var total=0
        for y in 0..<6 { for x in 0..<8 { total+=Int(base.load(fromByteOffset:((y*2+1)*h/12)*stride+(x*2+1)*w/16,as:UInt8.self)) } }
        return Double(total)/(48*255)
    }
    nonisolated private static func depth(at p:CGPoint,data:ARDepthData?)->Double? {
        guard let data,let confidence=data.confidenceMap else { return nil }
        let map=data.depthMap
        CVPixelBufferLockBaseAddress(map,.readOnly);CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly);CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(map),let conf=CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let w=CVPixelBufferGetWidth(map),h=CVPixelBufferGetHeight(map),x=Int(p.x*Double(w)),y=Int(p.y*Double(h))
        var values:[Float]=[]
        for dy in -1...1 { for dx in -1...1 {
            let a=x+dx,b=y+dy;guard a>=0,b>=0,a<w,b<h else { continue }
            let c=conf.load(fromByteOffset:b*CVPixelBufferGetBytesPerRow(confidence)+a,as:UInt8.self)
            let d=base.load(fromByteOffset:b*CVPixelBufferGetBytesPerRow(map)+a*4,as:Float.self)
            if c>=2,d.isFinite,d>0.2,d<1.1 { values.append(d) }
        } }
        guard values.count>=5 else { return nil };values.sort()
        guard values.last!-values.first!<0.08 else { return nil }
        return Double(values[values.count/2])
    }
}
