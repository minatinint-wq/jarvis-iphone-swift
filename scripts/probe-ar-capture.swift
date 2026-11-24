import ARKit

@main struct ARCaptureProbe {
    static func main() {
        for _ in 0..<10 {
            let normal=SpatialCaptureProfile.configuration(scanning:false)
            precondition(normal.planeDetection.isEmpty)
            precondition(normal.sceneReconstruction == .none)
            precondition(normal.environmentTexturing == .none)
            precondition(normal.frameSemantics.isEmpty)
            precondition(!normal.isLightEstimationEnabled)
        }
        let manual=SpatialCaptureProfile.configuration(scanning:true)
        precondition(manual.planeDetection.contains(.horizontal))
        precondition(manual.planeDetection.contains(.vertical))
        precondition(manual.sceneReconstruction == .none)
        precondition(manual.environmentTexturing == .none)
        precondition(!manual.frameSemantics.contains(.personSegmentationWithDepth))
        precondition(manual.frameSemantics.contains(.smoothedSceneDepth) == ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth))
        precondition(SpatialCaptureProfile.scanSeconds == 8)
        print("AR_CAPTURE_LIGHT_OK planes=off mesh=off depth=off people=off environment=off")
        print("AR_CAPTURE_MANUAL_OK explicit surface/depth scan; duration=8 seconds")
    }
}
