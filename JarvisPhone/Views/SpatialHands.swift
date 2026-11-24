import ARKit
import Vision
import CoreImage
import UIKit

struct SpatialHandSample {
    let point:CGPoint
    let ratio:Double
    let menuPose:Bool
    let pointing:Bool
    let time:Double
    var worldPoint: SIMD3<Float>? = nil
    var palmWorld: SIMD3<Float>? = nil
    var openPalm = false
    var palmPoint: CGPoint? = nil
    var palmSpan: Double? = nil
}

enum SpatialHandMath {
    static func rawPoint(_ location:CGPoint,orientation:CGImagePropertyOrientation)->CGPoint {
        let p=CGPoint(x:location.x,y:1-location.y)
        switch orientation {
        case .right:return CGPoint(x:p.y,y:1-p.x)
        case .left:return CGPoint(x:1-p.y,y:p.x)
        case .down:return CGPoint(x:1-p.x,y:1-p.y)
        default:return p
        }
    }
    static func pointing(_ joints: [CGPoint?], twoFingers: Bool = false) -> Bool {
        guard joints.count == 21 else { return false }
        // Cosine at PIP in display coordinates: a straight finger approaches 1.
        func extensionScore(_ base: Int) -> CGFloat? {
            guard let knuckle = joints[base], let middle = joints[base+1], let tip = joints[base+3] else { return nil }
            let a = CGPoint(x:middle.x-knuckle.x,y:middle.y-knuckle.y)
            let b = CGPoint(x:tip.x-middle.x,y:tip.y-middle.y)
            let length = hypot(a.x,a.y)*hypot(b.x,b.y)
            guard length > 1 else { return nil }
            return (a.x*b.x+a.y*b.y)/length
        }
        guard let index = extensionScore(5), index > 0.60 else { return false }
        if twoFingers {
            guard let middle=extensionScore(9), middle > 0.60, let ring=extensionScore(13), let little=extensionScore(17) else { return false }
            return ring < 0.5 && little < 0.5
        }
        let others = [9,13,17].compactMap(extensionScore)
        return others.count >= 2 && others.allSatisfy { $0 < 0.5 }
    }
    static func openPalm(_ joints: [CGPoint?]) -> Bool {
        guard joints.count==21 else { return false }
        return [5,9,13,17].allSatisfy { base in
            guard let a=joints[base],let b=joints[base+1],let c=joints[base+3] else { return false }
            let ux=b.x-a.x,uy=b.y-a.y,vx=c.x-b.x,vy=c.y-b.y
            let length=hypot(ux,uy)*hypot(vx,vy)
            return length>1 && (ux*vx+uy*vy)/length>0.75
        }
    }
    /// Scene depth is in captured-image coordinates. Require a coherent patch
    /// with high confidence, rather than reading a single mixed edge pixel.
    static func worldPoint(_ point: CGPoint, frame: ARFrame) -> SIMD3<Float>? {
        guard let depth=frame.smoothedSceneDepth,let confidence=depth.confidenceMap else { return nil }
        let map=depth.depthMap
        CVPixelBufferLockBaseAddress(map,.readOnly);CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly);CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        guard let values=CVPixelBufferGetBaseAddress(map),let levels=CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let w=CVPixelBufferGetWidth(map),h=CVPixelBufferGetHeight(map)
        let x=Int(point.x*Double(w)),y=Int(point.y*Double(h))
        guard x>0,y>0,x<w-1,y<h-1 else { return nil }
        var samples:[Float]=[]
        for row in (y-1)...(y+1) { for column in (x-1)...(x+1) {
            guard levels.load(fromByteOffset:row*CVPixelBufferGetBytesPerRow(confidence)+column,as:UInt8.self)==2 else { continue }
            let d=values.load(fromByteOffset:row*CVPixelBufferGetBytesPerRow(map)+column*4,as:Float.self)
            if d.isFinite,(0.15...2).contains(d) { samples.append(d) }
        }}
        guard samples.count>=6,let low=samples.min(),let high=samples.max(),high-low<0.045 else { return nil }
        samples.sort();let d=samples[samples.count/2],k=frame.camera.intrinsics,size=frame.camera.imageResolution
        let p=SIMD4<Float>((Float(point.x*size.width)-k[2][0])*d/k[0][0],-(Float(point.y*size.height)-k[2][1])*d/k[1][1],-d,1)
        let world=frame.camera.transform*p
        return SIMD3(world.x,world.y,world.z)
    }
    /// The wrist may be outside the camera image. Knuckles still define palm scale.
    static func pinchRatio(_ points:[CGPoint?],size:CGSize)->Double? {
        guard points.count==21,let index=points[8],let thumb=points[4] else { return nil }
        func d(_ a:CGPoint,_ b:CGPoint)->Double { hypot((a.x-b.x)*size.width,(a.y-b.y)*size.height) }
        for (a,b,factor) in [(5,17,1.0),(0,9,1.0),(5,9,2.5),(5,6,2.0)] {
            if let p=points[a],let q=points[b] {
                let scale=d(p,q)*factor
                if scale>=18 { return d(index,thumb)/scale }
            }
        }
        return nil
    }
}

/// Native adapter for the iPhone: uses ARKit's existing camera, never opens a
/// second capture session. Hand-OSC-Lab inspired the temporal input design;
/// its WebXR 25-joint runtime is not shipped as an iPhone hand tracker.
@MainActor final class SpatialHands {
    private let queue=DispatchQueue(label:"jarvis.spatial.hands",qos:.userInitiated)
    private let handRequest=VNDetectHumanHandPoseRequest()
    private var busy=false
    private var lastFrame:Double = -.infinity
    private var generation=0
    private var wasEnabled=false
    private var smoothed:CGPoint?
    private var smoothedWorld:SIMD3<Float>?
    private var smoothedPalm:SIMD3<Float>?
    private var lastSeen:Double=0
    private var lastRawTip:CGPoint?
    private var lastReport:Double=0
    private(set) var latencyMS=0.0
    private(set) var hasHand=false
    private(set) var hasDepth=false
    private let cursor=UIView(frame:CGRect(x:0,y:0,width:24,height:24))
    private let overlay=UIView()
    private let bones=CAShapeLayer()
    var onSample:((SpatialHandSample?)->Void)?
    var onQuality:((String)->Void)?
    private var quality=""
    init(view:ARSCNView) {
        handRequest.maximumHandCount=2
        overlay.frame=view.bounds;overlay.autoresizingMask=[.flexibleWidth,.flexibleHeight]
        overlay.isUserInteractionEnabled=false;overlay.backgroundColor = .clear;overlay.isOpaque=false
        view.addSubview(overlay)
        cursor.isUserInteractionEnabled=false;cursor.layer.cornerRadius=12;cursor.layer.borderWidth=2;cursor.layer.borderColor=UIColor.cyan.cgColor
        cursor.backgroundColor=UIColor.cyan.withAlphaComponent(0.18);cursor.isHidden=true;overlay.addSubview(cursor)
        bones.strokeColor=UIColor.cyan.withAlphaComponent(0.85).cgColor;bones.fillColor=UIColor.clear.cgColor;bones.lineWidth=1.8
        overlay.layer.addSublayer(bones)
        dwellRing.path = UIBezierPath(ovalIn:cursor.bounds.insetBy(dx: -3,dy: -3)).cgPath
        dwellRing.strokeColor = UIColor.white.cgColor
        dwellRing.fillColor = nil
        dwellRing.lineWidth = 3
        dwellRing.strokeEnd = 0
        cursor.layer.addSublayer(dwellRing)
    }
    private let dwellRing = CAShapeLayer()
    func showProgress(_ value: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dwellRing.strokeEnd = CGFloat(value)
        CATransaction.commit()
    }
    func reset() { showProgress(0);generation+=1;cursor.isHidden=true;bones.path=nil;smoothed=nil;smoothedWorld=nil;smoothedPalm=nil;lastRawTip=nil;onSample?(nil) }
    private func report(_ text:String) { let now=ProcessInfo.processInfo.systemUptime;if text != quality,now-lastReport>0.3 { lastReport=now;quality=text;onQuality?(text) } }
    func update(_ frame:ARFrame,view:ARSCNView,enabled:Bool) {
        overlay.isHidden = !enabled
        guard enabled else { if wasEnabled { reset() };wasEnabled=false;return };wasEnabled=true
        if view.subviews.last !== overlay { view.bringSubviewToFront(overlay) }
        bones.frame=overlay.bounds
        let interval=ProcessInfo.processInfo.thermalState == .serious ? 0.125 : 1.0/15
        guard !busy,frame.timestamp-lastFrame>=interval else { return }
        busy=true;lastFrame=frame.timestamp
        let ticket=generation,stamp=ProcessInfo.processInfo.systemUptime,size=view.bounds.size
        let request=handRequest,previousTip=lastRawTip
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform=frame.displayTransform(for:orientation,viewportSize:size)
        let imageOrientation:CGImagePropertyOrientation=orientation == .landscapeLeft ? .down : orientation == .landscapeRight ? .up : orientation == .portraitUpsideDown ? .left : .right
        let pixels=frame.capturedImage,resolution=frame.camera.imageResolution
        queue.async {
            let luminance=Self.luminance(pixels)
            var positions:[CGPoint?]=[];var ratio:Double?;var rawTip:CGPoint?;var rawPalm:CGPoint?;var detectorError=false
            do {
                if luminance<0.10 {
                    let image=CIImage(cvPixelBuffer:pixels).applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.7])
                    try VNImageRequestHandler(ciImage:image,orientation:imageOrientation).perform([request])
                } else {
                    try VNImageRequestHandler(cvPixelBuffer:pixels,orientation:imageOrientation).perform([request])
                }
                let keys:[VNHumanHandPoseObservation.JointName]=[.wrist,.thumbCMC,.thumbMP,.thumbIP,.thumbTip,.indexMCP,.indexPIP,.indexDIP,.indexTip,.middleMCP,.middlePIP,.middleDIP,.middleTip,.ringMCP,.ringPIP,.ringDIP,.ringTip,.littleMCP,.littlePIP,.littleDIP,.littleTip]
                let candidates=(request.results ?? []).compactMap { hand -> [VNHumanHandPoseObservation.JointName:VNRecognizedPoint]? in
                    guard let joints=try? hand.recognizedPoints(.all),let tip=joints[.indexTip],tip.confidence>=0.35 else { return nil };return joints
                }
                let joints=candidates.min { a,b in
                    func score(_ j:[VNHumanHandPoseObservation.JointName:VNRecognizedPoint])->CGFloat {
                        let tip=SpatialHandMath.rawPoint(j[.indexTip]!.location,orientation:imageOrientation)
                        return previousTip.map { hypot(tip.x-$0.x,tip.y-$0.y) } ?? CGFloat(1-j[.indexTip]!.confidence)
                    }
                    return score(a)<score(b)
                }
                if let joints {
                    let raw=keys.map { key -> CGPoint? in
                        guard let p=joints[key],p.confidence>=0.30 else { return nil }
                        return SpatialHandMath.rawPoint(p.location,orientation:imageOrientation)
                    }
                    positions=raw.map { $0.map { p in let q=p.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) } }
                    let palm=[0,5,9,13,17].compactMap { raw[$0] }
                    if palm.count>=4 { rawPalm=CGPoint(x:palm.map(\.x).reduce(0,+)/CGFloat(palm.count),y:palm.map(\.y).reduce(0,+)/CGFloat(palm.count)) }
                    if let tip=raw[8] {
                        rawTip=tip
                        if (joints[.indexTip]?.confidence ?? 0)>=0.50,(joints[.thumbTip]?.confidence ?? 0)>=0.50 {
                            ratio=SpatialHandMath.pinchRatio(raw,size:resolution)
                        }
                    }
                }
            } catch { detectorError=true }
            let result=positions,amount=ratio,tip=rawTip,palm=rawPalm,failed=detectorError
            Task { @MainActor [weak self] in
                guard let self else { return };self.busy=false
                guard self.generation==ticket else { return }
                let now=ProcessInfo.processInfo.systemUptime
                self.latencyMS=(now-stamp)*1000;self.hasHand=false;self.hasDepth=false
                guard now-stamp<0.45 else { self.cursor.isHidden=true;self.bones.path=nil;self.onSample?(nil);self.report("Detector atrasado. Gestos pausados até atualizar a mão.");return }
                guard result.count==21,let point=result[8],CGRect(origin:.zero,size:size).contains(point) else {
                    if now-self.lastSeen>0.18 { self.cursor.isHidden=true;self.bones.path=nil;self.smoothed=nil }
                    self.report(failed ? "O detector não processou a imagem. Toque nos cartões enquanto ele retoma." : luminance<0.10 ? "Pouca luz na imagem. Mostre indicador e polegar à câmera." : "Indicador ainda não localizado. Afaste um pouco a mão da lente.")
                    self.onSample?(nil);return
                }
                let dt=max(0.001,min(0.15,now-self.lastSeen)),alpha=1-exp(-dt/0.035)
                let p=self.smoothed.map { CGPoint(x:$0.x+(point.x-$0.x)*alpha,y:$0.y+(point.y-$0.y)*alpha) } ?? point
                self.smoothed=p;self.lastSeen=now;self.lastRawTip=tip;self.cursor.center=p;self.cursor.isHidden=false
                self.hasHand=true
                self.cursor.layer.borderColor=(amount == nil ? UIColor.yellow : amount!<0.28 ? UIColor.orange : .cyan).cgColor
                let path=UIBezierPath()
                for chain in [[0,1,2,3,4],[0,5,6,7,8],[0,9,10,11,12],[0,13,14,15,16],[0,17,18,19,20],[5,9,13,17]] {
                    for pair in zip(chain,chain.dropFirst()) { if let a=result[pair.0],let b=result[pair.1] { path.move(to:a);path.addLine(to:b) } }
                }
                self.bones.path=path.cgPath
                let pointing = SpatialHandMath.pointing(result)
                self.report(pointing ? "Indicador · mantenha sobre o alvo por 2 segundos" : amount == nil ? "Mostre indicador e polegar para usar pinça." : amount! < 0.28 ? "Pinça · arrastar" : "Mão livre")
                let world=tip.flatMap { SpatialHandMath.worldPoint($0,frame:frame) },palmWorld=palm.flatMap { SpatialHandMath.worldPoint($0,frame:frame) }
                self.hasDepth=world != nil
                self.smoothedWorld=world.map { value in self.smoothedWorld.map { $0+(value-$0)*Float(alpha) } ?? value }
                self.smoothedPalm=palmWorld.map { value in self.smoothedPalm.map { $0+(value-$0)*Float(alpha) } ?? value }
                let palmPoint=palm.map { raw -> CGPoint in let q=raw.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) }
                let span:Double?
                if let a=result[5],let b=result[17] { span=Double(hypot(a.x-b.x,a.y-b.y)/sqrt(max(1,size.width*size.height))) } else { span=nil }
                self.onSample?(SpatialHandSample(point:p,ratio:amount ?? .nan,menuPose:SpatialHandMath.pointing(result,twoFingers:true),pointing:pointing,time:stamp,worldPoint:self.smoothedWorld,palmWorld:self.smoothedPalm,openPalm:SpatialHandMath.openPalm(result),palmPoint:palmPoint,palmSpan:span))
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
}
