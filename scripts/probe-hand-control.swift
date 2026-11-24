import Foundation
import Vision
import CoreImage

@main struct HandControlProbe {
    static func main() throws {
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
