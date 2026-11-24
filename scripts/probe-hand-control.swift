import Foundation
import Vision
import CoreImage

@main struct HandControlProbe {
    static func main() throws {
        var slowPose=SpatialPoseStability()
        for tick in 0...30 { precondition(slowPose.update(position:SIMD3(0,0,0),forward:SIMD3(0,0,1),time:Double(tick)*0.5)) }
        var dual=SpatialDualPinchScale(),size:Float=1
        for tick in 0...30 {
            let distance=100+Double(tick)*5
            size *= dual.update(points:[CGPoint(x:0,y:0),CGPoint(x:distance,y:0)],time:Double(tick)*0.1) ?? 1
        }
        precondition(size>2 && dual.active)
        _=dual.update(points:nil,time:3.2);precondition(dual.active)
        _=dual.update(points:nil,time:3.5);precondition(!dual.active)
        print("VR_SLOW_FRAME_AND_DUAL_PINCH_OK normal tracking tolerates slow callbacks; both pinches resize; loss releases safely")
        var typing=SpatialGesture(dwellDuration:0.55)
        _=typing.update(ratio:1,pointing:true,target:"q",time:0)
        precondition(typing.update(ratio:1,pointing:true,target:"q",time:0.6)==[.click("q")])
        typing.reset();_=typing.update(ratio:1,pointing:true,target:"q",time:1)
        precondition(typing.update(ratio:1,pointing:true,target:"q",time:1.6)==[.click("q")])
        var scrolling=SpatialDesktopScroll()
        precondition(scrolling.update(point:CGPoint(x:0.5,y:0.5),time:0)==nil)
        precondition((scrolling.update(point:CGPoint(x:0.5,y:0.4),time:0.1) ?? 0)<0)
        print("PROJECTED_KEYBOARD_AND_SCROLL_OK typing dwell survives reset; two-finger motion yields wheel steps")
        var frames=SpatialFrameGate()
        precondition(frames.accept(10));precondition(!frames.accept(10));precondition(!frames.accept(9));precondition(!frames.accept(.nan));precondition(frames.accept(10.1))
        var pose=SpatialPoseStability()
        for tick in 0...60 { precondition(pose.update(position:SIMD3(Float(tick)*0.001,0,0),forward:SIMD3(0,0,1),time:Double(tick)/60)) }
        precondition(!pose.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:61.0/60))
        for tick in 62...107 { precondition(!pose.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:Double(tick)/60)) }
        precondition(pose.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:110.0/60))
        var stationary=SpatialPinchZoom()
        stationary.begin(span:0.2,depth:nil,time:0)
        for tick in 1...600 { precondition(stationary.update(span:0.2*(1+sin(Double(tick))*0.035),depth:nil,time:Double(tick)*0.1)==nil) }
        stationary.begin(span:0.2,depth:0.6,time:61)
        precondition(stationary.update(span:0.6,depth:nil,time:61.1)==nil)
        precondition(stationary.update(span:0.6,depth:0.6,time:61.2)==nil)
        print("SPATIAL_STABILITY_OK pose jumps settle; stationary pinch has no cumulative zoom; no source switching")
        var gate=WallTrackingGate()
        precondition(!gate.update(normal:true,at:0))
        precondition(gate.update(normal:true,at:0.7))
        precondition(gate.update(normal:false,at:1.2,transient:true))
        precondition(gate.update(normal:true,at:1.3))
        precondition(!gate.update(normal:false,at:1.4)) // real relocalization
        precondition(!gate.update(normal:true,at:1.5))
        precondition(gate.update(normal:true,at:2.2))
        precondition(!gate.update(normal:false,at:3.5,transient:true)) // bounded grace
        precondition(!gate.update(normal:false,at:4,transient:true))
        precondition(!gate.update(normal:true,at:4.1))
        precondition(!gate.update(normal:false,at:.nan))

        var zoom=SpatialPinchZoom()
        precondition(zoom.update(span:0.3,depth:nil,time:0)==nil)
        zoom.begin(span:0.2,depth:nil,time:0)
        var enlarged:[Float]=[]
        for i in 1...8 { if let f=zoom.update(span:0.2+Double(i)*0.02,depth:nil,time:Double(i)/10) { enlarged.append(f) } }
        precondition(!enlarged.isEmpty && enlarged.allSatisfy { $0>1 })
        var reduced:[Float]=[]
        for i in 1...10 { if let f=zoom.update(span:0.36-Double(i)*0.02,depth:nil,time:0.8+Double(i)/10) { reduced.append(f) } }
        precondition(reduced.contains { $0<1 })
        precondition(zoom.update(span:0.4,depth:nil,time:3)==nil) // a lost pinch cannot resize later
        zoom.begin(span:0.2,depth:0.6,time:4)
        precondition((zoom.update(span:0.2,depth:0.4,time:4.1) ?? 0)>1)
        precondition(zoom.update(span:.nan,depth:nil,time:4.2)==nil)

        var gesture=SpatialGesture()
        precondition(gesture.update(ratio:0.1,pointing:false,target:"panel",time:0).isEmpty)
        precondition(gesture.update(ratio:0.1,pointing:false,target:"panel",time:0.2)==[.press("panel")])
        precondition(gesture.update(ratio:.nan,pointing:false,target:nil,time:0.3).isEmpty)
        precondition(gesture.update(ratio:0.1,pointing:false,target:nil,time:0.4)==[.drag("panel")])
        precondition(gesture.update(ratio:1,pointing:false,target:nil,time:0.5)==[.release])
        _=gesture.update(ratio:0.1,pointing:false,target:"panel",time:1)
        precondition(gesture.update(ratio:0.1,pointing:false,target:"panel",time:1.2)==[.press("panel")])
        precondition(gesture.update(ratio:.nan,pointing:false,target:nil,time:1.3).isEmpty)
        precondition(gesture.update(ratio:.nan,pointing:false,target:nil,time:1.6)==[.cancel])
        precondition(HandPoseInput.recognizable([0.2,0.2,0.2,0.2,0.2]))
        precondition(!HandPoseInput.recognizable([0.2,0.2,0.2,0.2,0.1]))
        print("HAND_CONTROL_POLICY_OK transient tracking, bounded recovery, pinch zoom and target ownership")

        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        for name in ["pointing_up","thumb_up","cats_and_dogs"] {
            guard let original=CIImage(contentsOf:directory.appendingPathComponent(name+".jpg")) else { fatalError("Missing public test image") }
            for dim in [false,true] {
                let source=dim ? original.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-1.3]) : original
                let image=HandPoseInput.prepare(source,luminance:dim ? 0.08 : 0.5)
                precondition(max(image.extent.width,image.extent.height)<=640.01)
                let request=VNDetectHumanHandPoseRequest();request.maximumHandCount=2
                let start=ProcessInfo.processInfo.systemUptime
                try VNImageRequestHandler(ciImage:image,orientation:.up).perform([request])
                let recognized=try (request.results ?? []).map { try $0.recognizedPoints(.all) }
                    .filter { HandPoseInput.recognizable($0.values.map(\.confidence)) }
                precondition(name == "cats_and_dogs" ? recognized.isEmpty : !recognized.isEmpty,"Vision fixture failed: "+name)
                print("VISION_HAND_FIXTURE_OK \(name) dim=\(dim) hands=\(recognized.count) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000))")
            }
        }
    }
}
