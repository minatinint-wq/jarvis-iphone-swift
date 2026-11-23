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
    private var lastSeen:Double=0
    private var lastRawTip:CGPoint?
    private var lastReport:Double=0
    private let cursor=UIView(frame:CGRect(x:0,y:0,width:24,height:24))
    private let bones=CAShapeLayer()
    var onSample:((SpatialHandSample?)->Void)?
    var onQuality:((String)->Void)?
    private var quality=""
    init(view:ARSCNView) {
        handRequest.maximumHandCount=2
        cursor.isUserInteractionEnabled=false;cursor.layer.cornerRadius=12;cursor.layer.borderWidth=2;cursor.layer.borderColor=UIColor.cyan.cgColor
        cursor.backgroundColor=UIColor.cyan.withAlphaComponent(0.18);cursor.isHidden=true;view.addSubview(cursor)
        bones.strokeColor=UIColor.cyan.withAlphaComponent(0.65).cgColor;bones.fillColor=UIColor.clear.cgColor;bones.lineWidth=1.3
        view.layer.addSublayer(bones)
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
    func reset() { showProgress(0);generation+=1;cursor.isHidden=true;bones.path=nil;smoothed=nil;lastRawTip=nil;onSample?(nil) }
    private func report(_ text:String) { let now=ProcessInfo.processInfo.systemUptime;if text != quality,now-lastReport>0.3 { lastReport=now;quality=text;onQuality?(text) } }
    func update(_ frame:ARFrame,view:ARSCNView,enabled:Bool) {
        guard enabled else { if wasEnabled { reset() };wasEnabled=false;return };wasEnabled=true
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
            var positions:[CGPoint?]=[];var ratio:Double?;var rawTip:CGPoint?;var detectorError=false
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
                    if let tip=raw[8] {
                        rawTip=tip
                        if (joints[.indexTip]?.confidence ?? 0)>=0.50,(joints[.thumbTip]?.confidence ?? 0)>=0.50 {
                            ratio=SpatialHandMath.pinchRatio(raw,size:resolution)
                        }
                    }
                }
            } catch { detectorError=true }
            let result=positions,amount=ratio,tip=rawTip,failed=detectorError
            Task { @MainActor [weak self] in
                guard let self else { return };self.busy=false
                guard self.generation==ticket else { return }
                let now=ProcessInfo.processInfo.systemUptime
                guard now-stamp<0.65 else { self.cursor.isHidden=true;self.bones.path=nil;self.onSample?(nil);self.report("Detector atrasado. Gestos pausados até atualizar a mão.");return }
                guard result.count==21,let point=result[8],CGRect(origin:.zero,size:size).contains(point) else {
                    if now-self.lastSeen>0.18 { self.cursor.isHidden=true;self.bones.path=nil;self.smoothed=nil }
                    self.report(failed ? "O detector não processou a imagem. Toque nos cartões enquanto ele retoma." : luminance<0.10 ? "Pouca luz na imagem. Mostre indicador e polegar à câmera." : "Indicador ainda não localizado. Afaste um pouco a mão da lente.")
                    self.onSample?(nil);return
                }
                let dt=max(0.001,min(0.15,now-self.lastSeen)),alpha=1-exp(-dt/0.035)
                let p=self.smoothed.map { CGPoint(x:$0.x+(point.x-$0.x)*alpha,y:$0.y+(point.y-$0.y)*alpha) } ?? point
                self.smoothed=p;self.lastSeen=now;self.lastRawTip=tip;self.cursor.center=p;self.cursor.isHidden=false
                self.cursor.layer.borderColor=(amount == nil ? UIColor.yellow : amount!<0.28 ? UIColor.orange : .cyan).cgColor
                let path=UIBezierPath()
                for chain in [[0,1,2,3,4],[0,5,6,7,8],[0,9,10,11,12],[0,13,14,15,16],[0,17,18,19,20],[5,9,13,17]] {
                    for pair in zip(chain,chain.dropFirst()) { if let a=result[pair.0],let b=result[pair.1] { path.move(to:a);path.addLine(to:b) } }
                }
                self.bones.path=path.cgPath
                let pointing = SpatialHandMath.pointing(result)
                self.report(amount == nil ? "Mostre a mão inteira." : amount! < 0.28 ? "Pinça · arrastar" : pointing ? "Indicador · mantenha sobre o alvo" : "Mão livre")
                self.onSample?(SpatialHandSample(point:p,ratio:amount ?? .nan,menuPose:SpatialHandMath.pointing(result,twoFingers:true),pointing:pointing,time:stamp))
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
