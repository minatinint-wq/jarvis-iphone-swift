import Foundation
import CoreImage

enum HandPoseInput {
    static let jointConfidence:Float=0.18
    static let pointerConfidence:Float=0.28
    static let pinchConfidence:Float=0.35
    static func recognizable(_ confidence:[Float]) -> Bool {
        confidence.filter { $0>=jointConfidence }.count>=5
    }
    /// Normalized joint coordinates remain unchanged by this aspect-preserving resize.
    static func prepare(_ image:CIImage,luminance:Double) -> CIImage {
        let side=max(image.extent.width,image.extent.height)
        guard side.isFinite,side>0 else { return image }
        var result=image.transformed(by:CGAffineTransform(scaleX:min(1,640/side),y:min(1,640/side)))
        if luminance<0.16 { result=result.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:0.65]) }
        return result
    }
}
