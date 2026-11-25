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
    var dualPinch:[CGPoint]? = nil
    var keyboardPose=false
    var closedFist=false
}

enum SpatialHandMath {
    /// All four fingers folded toward the palm. A thumb/index pinch with the
    /// other fingers extended is deliberately excluded, independent of rotation.
    static func closedFist(_ joints:[CGPoint?])->Bool {
        guard joints.count==21,let wrist=joints[0],let left=joints[5],let right=joints[17] else { return false }
        let scale=hypot(left.x-right.x,left.y-right.y)
        guard scale>18 else { return false }
        for base in [5,9,13,17] {
            guard let a=joints[base],let b=joints[base+1],let tip=joints[base+3] else { return false }
            let u=CGPoint(x:b.x-a.x,y:b.y-a.y),v=CGPoint(x:tip.x-b.x,y:tip.y-b.y)
            let length=hypot(u.x,u.y)*hypot(v.x,v.y)
            guard length>1,(u.x*v.x+u.y*v.y)/length<0.15,
                  hypot(tip.x-wrist.x,tip.y-wrist.y)<hypot(b.x-wrist.x,b.y-wrist.y)+scale*0.12 else { return false }
        }
        guard let thumb=joints[4],let middle=joints[9] else { return false }
        return hypot(thumb.x-middle.x,thumb.y-middle.y)<scale*1.15
    }
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
    static func keyboardPose(_ joints:[CGPoint?])->Bool {
        guard joints.count==21 else { return false }
        func score(_ base:Int)->CGFloat? {
            guard let a=joints[base],let b=joints[base+1],let c=joints[base+3] else { return nil }
            let u=CGPoint(x:b.x-a.x,y:b.y-a.y),v=CGPoint(x:c.x-b.x,y:c.y-b.y)
            let length=hypot(u.x,u.y)*hypot(v.x,v.y)
            return length>1 ? (u.x*v.x+u.y*v.y)/length : nil
        }
        guard let little=score(17),little<0.5 else { return false }
        return [5,9,13].allSatisfy { (score($0) ?? -1)>0.60 }
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
    private var handRequest=VNDetectHumanHandPoseRequest()
    private var busy=false
    private var busySince=0.0
    private var cancellationRequested=false
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
    private weak var homeView:UIView?
    func presentOverlay(in host:UIView?) {
        guard let target=host ?? homeView else { return }
        overlay.removeFromSuperview();overlay.frame=target.bounds;target.addSubview(overlay)
    }
    private let bones=CAShapeLayer()
    private var skeletonVisible=true
    func setSkeletonVisible(_ visible:Bool) { skeletonVisible=visible;bones.isHidden = !visible;mirrorBones?.isHidden = !visible }
    private var mirror:UIView?
    private var mirrorBones:CAShapeLayer?
    private var mirrorCursor:UIView?
    private var mirrorRing:CAShapeLayer?
    func mirrorOverlay(in host:UIView?) {
        mirror?.removeFromSuperview();mirror=nil;mirrorBones=nil;mirrorCursor=nil;mirrorRing=nil
        guard let host else { return }
        let overlay=UIView(frame:host.bounds);overlay.autoresizingMask=[.flexibleWidth,.flexibleHeight]
        overlay.isUserInteractionEnabled=false;overlay.backgroundColor = .clear
        let bones=CAShapeLayer();bones.strokeColor=self.bones.strokeColor;bones.fillColor=UIColor.clear.cgColor;bones.lineWidth=1.8
        overlay.layer.addSublayer(bones)
        let cursor=UIView(frame:self.cursor.bounds);cursor.layer.cornerRadius=12;cursor.layer.borderWidth=2
        cursor.backgroundColor=self.cursor.backgroundColor;overlay.addSubview(cursor)
        let ring=CAShapeLayer();ring.path=dwellRing.path;ring.strokeColor=UIColor.white.cgColor;ring.fillColor=nil;ring.lineWidth=3
        cursor.layer.addSublayer(ring);host.addSubview(overlay)
        mirror=overlay;mirrorBones=bones;mirrorCursor=cursor;mirrorRing=ring
        syncMirror()
    }
    private func syncMirror() {
        guard let mirror else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        mirror.isHidden=overlay.isHidden
        mirrorBones?.frame=mirror.bounds;mirrorBones?.path=bones.path;mirrorBones?.opacity=bones.opacity
        mirrorBones?.isHidden = !skeletonVisible
        mirrorCursor?.center=cursor.center;mirrorCursor?.isHidden=cursor.isHidden
        mirrorCursor?.layer.borderColor=cursor.layer.borderColor;mirrorRing?.strokeEnd=dwellRing.strokeEnd
        CATransaction.commit()
    }
    var onSample:((SpatialHandSample?)->Void)?
    var onQuality:((String)->Void)?
    private var quality=""
    init(view:ARSCNView) {
        homeView=view
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
        mirrorRing?.strokeEnd = CGFloat(value)
        CATransaction.commit()
    }
    func reset() { showProgress(0);generation+=1;lastFrame = -.infinity;cursor.isHidden=true;bones.path=nil;smoothed=nil;smoothedWorld=nil;smoothedPalm=nil;lastRawTip=nil;onSample?(nil);syncMirror() }
    private func report(_ text:String) { let now=ProcessInfo.processInfo.systemUptime;if text != quality,now-lastReport>0.3 { lastReport=now;quality=text;onQuality?(text) } }
    func update(_ frame:ARFrame,view:ARSCNView,enabled:Bool) {
        overlay.isHidden = !enabled
        syncMirror()
        guard enabled else { if wasEnabled { reset() };wasEnabled=false;return };wasEnabled=true
        if overlay.superview === view,view.subviews.last !== overlay { view.bringSubviewToFront(overlay) }
        bones.frame=overlay.bounds
        let now=ProcessInfo.processInfo.systemUptime
        if busy {
            if now-busySince>3 && !cancellationRequested {
                cancellationRequested=true;handRequest.cancel();report("Retomando o detector da mão…")
            }
            return
        }
        let interval=ProcessInfo.processInfo.thermalState == .serious ? 0.16 : 0.10
        guard now-lastFrame>=interval else { return }
        busy=true;busySince=now;cancellationRequested=false;lastFrame=now
        handRequest=VNDetectHumanHandPoseRequest();handRequest.maximumHandCount=2
        let ticket=generation,stamp=ProcessInfo.processInfo.systemUptime,size=view.bounds.size
        let request=handRequest,previousTip=lastRawTip
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform=frame.displayTransform(for:orientation,viewportSize:size)
        let imageOrientation:CGImagePropertyOrientation=orientation == .landscapeLeft ? .down : orientation == .landscapeRight ? .up : orientation == .portraitUpsideDown ? .left : .right
        let pixels=frame.capturedImage,resolution=frame.camera.imageResolution
        queue.async {
            autoreleasepool {
            let luminance=Self.luminance(pixels)
            var positions:[CGPoint?]=[];var ratio:Double?;var rawTip:CGPoint?;var rawPalm:CGPoint?;var detectorError=false
            var dualPinch:[CGPoint]?
            do {
                let image=HandPoseInput.prepare(CIImage(cvPixelBuffer:pixels),luminance:luminance)
                try VNImageRequestHandler(ciImage:image,orientation:imageOrientation).perform([request])
                let keys:[VNHumanHandPoseObservation.JointName]=[.wrist,.thumbCMC,.thumbMP,.thumbIP,.thumbTip,.indexMCP,.indexPIP,.indexDIP,.indexTip,.middleMCP,.middlePIP,.middleDIP,.middleTip,.ringMCP,.ringPIP,.ringDIP,.ringTip,.littleMCP,.littlePIP,.littleDIP,.littleTip]
                let candidates=(request.results ?? []).compactMap { hand -> [VNHumanHandPoseObservation.JointName:VNRecognizedPoint]? in
                    guard let joints=try? hand.recognizedPoints(.all),HandPoseInput.recognizable(joints.values.map(\.confidence)) else { return nil };return joints
                }
                let pinches=candidates.compactMap { joints -> CGPoint? in
                    guard let a=joints[.thumbTip],let b=joints[.indexTip],min(a.confidence,b.confidence)>=HandPoseInput.pinchConfidence else { return nil }
                    let raw=keys.map { key -> CGPoint? in
                        guard let joint=joints[key],joint.confidence>=HandPoseInput.jointConfidence else { return nil }
                        return SpatialHandMath.rawPoint(joint.location,orientation:imageOrientation)
                    }
                    guard let ratio=SpatialHandMath.pinchRatio(raw,size:resolution),ratio<0.40,let thumb=raw[4],let index=raw[8] else { return nil }
                    let q=CGPoint(x:(thumb.x+index.x)/2,y:(thumb.y+index.y)/2).applying(transform)
                    return CGPoint(x:q.x*size.width,y:q.y*size.height)
                }
                if pinches.count==2 { dualPinch=pinches.sorted { $0.x<$1.x } }
                let joints=candidates.min { a,b in
                    func score(_ j:[VNHumanHandPoseObservation.JointName:VNRecognizedPoint])->CGFloat {
                        let visible=j.values.filter { $0.confidence>=HandPoseInput.jointConfidence }
                        let average=CGPoint(x:visible.map { $0.location.x }.reduce(0,+)/CGFloat(visible.count),y:visible.map { $0.location.y }.reduce(0,+)/CGFloat(visible.count))
                        let location=j[.indexTip].flatMap { $0.confidence>=HandPoseInput.pointerConfidence ? $0.location : nil } ?? average
                        let tip=SpatialHandMath.rawPoint(location,orientation:imageOrientation)
                        return previousTip.map { hypot(tip.x-$0.x,tip.y-$0.y) } ?? CGFloat(1-(j[.indexTip]?.confidence ?? 0))
                    }
                    return score(a)<score(b)
                }
                if let joints {
                    let raw=keys.map { key -> CGPoint? in
                        guard let p=joints[key],p.confidence>=HandPoseInput.jointConfidence else { return nil }
                        return SpatialHandMath.rawPoint(p.location,orientation:imageOrientation)
                    }
                    positions=raw.map { $0.map { p in let q=p.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) } }
                    let palm=[0,5,9,13,17].compactMap { raw[$0] }
                    if palm.count>=4 { rawPalm=CGPoint(x:palm.map(\.x).reduce(0,+)/CGFloat(palm.count),y:palm.map(\.y).reduce(0,+)/CGFloat(palm.count)) }
                    if let tip=raw[8],(joints[.indexTip]?.confidence ?? 0)>=HandPoseInput.pointerConfidence {
                        rawTip=tip
                        if (joints[.indexTip]?.confidence ?? 0)>=HandPoseInput.pinchConfidence,(joints[.thumbTip]?.confidence ?? 0)>=HandPoseInput.pinchConfidence {
                            ratio=SpatialHandMath.pinchRatio(raw,size:resolution)
                        }
                    }
                }
            } catch { detectorError=true }
            let result=positions,amount=ratio,tip=rawTip,palm=rawPalm,failed=detectorError,both=dualPinch
            Task { @MainActor [weak self] in
                guard let self else { return };self.busy=false
                defer { self.syncMirror() }
                guard self.generation==ticket else { return }
                let now=ProcessInfo.processInfo.systemUptime
                self.latencyMS=(now-stamp)*1000;self.hasHand=false;self.hasDepth=false
                guard now-stamp<0.9 else { self.cursor.isHidden=true;if now-self.lastSeen>0.45 { self.bones.path=nil };self.onSample?(nil);self.report("Detector atrasado. Retomando a mão…");return }
                guard result.count==21,result.compactMap({$0}).count>=5 else {
                    if now-self.lastSeen>0.45 { self.cursor.isHidden=true;self.bones.path=nil;self.smoothed=nil }
                    self.report(failed ? "O detector não processou a imagem. Toque nos cartões enquanto ele retoma." : luminance<0.10 ? "Pouca luz na imagem. Mostre indicador e polegar à câmera." : "Indicador ainda não localizado. Afaste um pouco a mão da lente.")
                    self.onSample?(nil);return
                }
                let path=UIBezierPath()
                for chain in [[0,1,2,3,4],[0,5,6,7,8],[0,9,10,11,12],[0,13,14,15,16],[0,17,18,19,20],[5,9,13,17]] {
                    for pair in zip(chain,chain.dropFirst()) { if let a=result[pair.0],let b=result[pair.1] { path.move(to:a);path.addLine(to:b) } }
                }
                CATransaction.begin();CATransaction.setDisableActions(true)
                self.bones.path=path.cgPath;self.bones.opacity=now-stamp<0.45 ? 1 : 0.45
                CATransaction.commit()
                self.hasHand=true
                let closed=SpatialHandMath.closedFist(result)
                let palmScreen=palm.map { raw -> CGPoint in let q=raw.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) }
                guard let point=(closed ? palmScreen : result[8]),(closed || tip != nil),CGRect(origin:.zero,size:size).contains(point),now-stamp<0.45 else {
                    self.lastSeen=now;self.cursor.isHidden=true;self.onSample?(nil)
                    self.report(now-stamp>=0.45 ? "Mão encontrada · aguarde o detector atualizar." : "Mão encontrada · mostre a ponta do indicador.");return
                }
                let dt=max(0.001,min(0.15,now-self.lastSeen)),alpha=1-exp(-dt/0.035)
                let p=self.smoothed.map { CGPoint(x:$0.x+(point.x-$0.x)*alpha,y:$0.y+(point.y-$0.y)*alpha) } ?? point
                self.smoothed=p;self.lastSeen=now;self.lastRawTip=tip;self.cursor.center=p;self.cursor.isHidden=closed
                self.hasHand=true
                self.cursor.layer.borderColor=(amount == nil ? UIColor.yellow : amount!<0.28 ? UIColor.orange : .cyan).cgColor
                let pointing = SpatialHandMath.pointing(result)
                self.report(closed ? "Mão fechada · abrir catálogo de efeitos" : pointing ? "Indicador · mantenha sobre o alvo por 2 segundos" : amount == nil ? "Mostre indicador e polegar para usar pinça." : amount! < 0.28 ? "Pinça · arrastar" : "Mão livre")
                let world=tip.flatMap { SpatialHandMath.worldPoint($0,frame:frame) },palmWorld=palm.flatMap { SpatialHandMath.worldPoint($0,frame:frame) }
                self.hasDepth=world != nil
                self.smoothedWorld=world.map { value in self.smoothedWorld.map { $0+(value-$0)*Float(alpha) } ?? value }
                self.smoothedPalm=palmWorld.map { value in self.smoothedPalm.map { $0+(value-$0)*Float(alpha) } ?? value }
                let palmPoint=palm.map { raw -> CGPoint in let q=raw.applying(transform);return CGPoint(x:q.x*size.width,y:q.y*size.height) }
                let span:Double?
                if let a=result[5],let b=result[17] { span=Double(hypot(a.x-b.x,a.y-b.y)/sqrt(max(1,size.width*size.height))) } else { span=nil }
                self.onSample?(SpatialHandSample(point:p,ratio:amount ?? .nan,menuPose:SpatialHandMath.pointing(result,twoFingers:true),pointing:pointing,time:stamp,worldPoint:self.smoothedWorld,palmWorld:self.smoothedPalm,openPalm:SpatialHandMath.openPalm(result),palmPoint:palmPoint,palmSpan:span,dualPinch:both,keyboardPose:SpatialHandMath.keyboardPose(result),closedFist:closed))
            }
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
