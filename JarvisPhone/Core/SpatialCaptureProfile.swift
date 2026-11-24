import ARKit

/// The default session only tracks the camera and existing world anchors.
/// Surface/depth acquisition is an explicit, short-lived user operation.
enum SpatialCaptureProfile {
    static let scanSeconds: Double=8
    static func configuration(scanning: Bool) -> ARWorldTrackingConfiguration {
        let configuration=ARWorldTrackingConfiguration()
        configuration.planeDetection=scanning ? [.horizontal,.vertical] : []
        configuration.sceneReconstruction = .none
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled=false
        configuration.frameSemantics=[]
        if scanning && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        return configuration
    }
}
