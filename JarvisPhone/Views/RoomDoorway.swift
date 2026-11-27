import ARKit
import SceneKit
import UIKit

struct RoomDoorwayOpening { var pose:simd_float4x4;var width:Float;var height:Float }

@MainActor enum RoomDoorway {
    static func placement(point:CGPoint,view:ARSCNView,room:ScannedRoomWall,planes:[ARPlaneAnchor])->RoomDoorwayOpening? {
        guard let roomPose=room.pose,let center=room.floorCenter,let frame=view.session.currentFrame else { return nil }
        let inside=roomPose*SIMD4(center,1),floor=inside.y
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        func make(origin:SIMD3<Float>,normal:SIMD3<Float>,width:Float,height:Float)->RoomDoorwayOpening {
            var n=simd_normalize(SIMD3(normal.x,0,normal.z))
            if simd_dot(SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)-origin,n)<0 { n = -n }
            let u=simd_cross(SIMD3<Float>(0,1,0),n)
            return .init(pose:simd_float4x4(SIMD4(u,0),SIMD4(0,1,0,0),SIMD4(n,0),SIMD4(origin.x,floor+height/2,origin.z,1)),width:width,height:height)
        }
        // Prefer the current semantic door. Never widen it to fit a decorative effect.
        for p in planes where p.classification == .door && p.alignment == .vertical {
            let c=p.transform*SIMD4(p.center,1),projected=view.projectPoint(SCNVector3(c.x,c.y,c.z))
            guard projected.z>0,projected.z<1,hypot(CGFloat(projected.x)-point.x,CGFloat(projected.y)-point.y)<110,
                  p.extent.x>=0.6,p.extent.z>=1.6 else { continue }
            return make(origin:SIMD3(c.x,c.y,c.z),normal:SIMD3(p.transform.columns.1.x,0,p.transform.columns.1.z),width:min(1.25,p.extent.x-0.06),height:min(2.15,p.extent.z-0.05))
        }
        // An open doorway can be absent from the mesh. Confirm free depth beyond
        // the old wall, rather than drawing a rectangle over an arbitrary wall.
        guard let hit=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first,
              abs(hit.worldNormal.y)<0.2 else { return nil }
        let n=SIMD3<Float>(hit.worldNormal),origin=SIMD3<Float>(hit.worldCoordinates)
        var best:RoomDoorwayOpening?
        for shift:Float in [0,-0.16,0.16] {
            for width:Float in [0.62,0.76,0.90,1.04] {
                let u=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),n))
                let candidate=make(origin:origin+u*shift,normal:n,width:width,height:1.92)
                if clear(candidate,frame:frame,orientation:orientation,size:view.bounds.size) { best=candidate }
            }
        }
        return best
    }
    private static func clear(_ opening:RoomDoorwayOpening,frame:ARFrame,orientation:UIInterfaceOrientation,size:CGSize)->Bool {
        guard let depth=frame.smoothedSceneDepth,let confidence=depth.confidenceMap else { return false }
        let map=depth.depthMap;CVPixelBufferLockBaseAddress(map,.readOnly);CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly);CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        guard let values=CVPixelBufferGetBaseAddress(map),let levels=CVPixelBufferGetBaseAddress(confidence) else { return false }
        let w=CVPixelBufferGetWidth(map),h=CVPixelBufferGetHeight(map),transform=frame.displayTransform(for:orientation,viewportSize:size).inverted(),inverse=simd_inverse(frame.camera.transform)
        var beyond=0,blocked=0,bands=Set<Int>(),columns=Set<Int>()
        for row in 0..<9 { for col in 0..<7 {
            let p=opening.pose*SIMD4((Float(col)/6-0.5)*opening.width,(Float(row)/8-0.5)*(opening.height-0.15),0,1)
            let screen=frame.camera.projectPoint(SIMD3(p.x,p.y,p.z),orientation:orientation,viewportSize:size)
            let uv=CGPoint(x:screen.x/size.width,y:screen.y/size.height).applying(transform)
            let x=Int(uv.x*Double(w)),y=Int(uv.y*Double(h));guard x>=0,y>=0,x<w,y<h else { continue }
            guard levels.load(fromByteOffset:y*CVPixelBufferGetBytesPerRow(confidence)+x,as:UInt8.self)>=1 else { continue }
            let d=values.load(fromByteOffset:y*CVPixelBufferGetBytesPerRow(map)+x*4,as:Float.self),expected = -(inverse*p).z
            guard d.isFinite,expected>0.2,expected<4 else { continue }
            if d>expected+0.30 { beyond+=1;bands.insert(row/3);columns.insert(col/3) }
            else if d>=expected-0.18 { blocked+=1 }
        }}
        return beyond>=20 && blocked<=2 && bands.count==3 && columns.count==3
    }
}
