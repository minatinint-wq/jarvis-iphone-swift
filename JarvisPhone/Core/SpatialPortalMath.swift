import Foundation
import simd

struct SpatialPortalRecord: Codable, Equatable {
    var anchor: UUID
    var width: Float
    var height: Float
    var theme: String = "forest"
    var valid: Bool { width.isFinite && height.isFinite && (0.3...1.5).contains(width) && (0.4...2).contains(height) && theme == "forest" }
}

enum SpatialPortalMath {
    // A window into a separate scene: the camera moves, the aperture never does.
    static func projection(eye: SIMD3<Float>,width:Float,height:Float)->simd_float4x4? {
        guard eye.x.isFinite,eye.y.isFinite,eye.z.isFinite,eye.z>0.08,width>0,height>0 else { return nil }
        let n:Float=0.04,f:Float=40
        let l=(-width/2-eye.x)*n/eye.z,r=(width/2-eye.x)*n/eye.z
        let b=(-height/2-eye.y)*n/eye.z,t=(height/2-eye.y)*n/eye.z
        return simd_float4x4(SIMD4(2*n/(r-l),0,0,0),SIMD4(0,2*n/(t-b),0,0),
                            SIMD4((r+l)/(r-l),(t+b)/(t-b),-(f+n)/(f-n),-1),SIMD4(0,0,-2*f*n/(f-n),0))
    }
    static func outline(width:Float,height:Float)->[SIMD2<Float>] {
        (0..<40).map { i in
            let angle=Float(i)*2 * .pi/40
            let radius:Float=0.91+0.045*sin(Float(i)*2.71)+0.025*cos(Float(i)*4.13)
            return SIMD2(cos(angle)*width/2*radius,sin(angle)*height/2*radius)
        }
    }
    static func contains(_ point:SIMD2<Float>,triangles:[SIMD2<Float>])->Bool {
        guard triangles.count%3==0 else { return false }
        for i in stride(from:0,to:triangles.count,by:3) {
            let a=triangles[i],b=triangles[i+1],c=triangles[i+2]
            func cross(_ u:SIMD2<Float>,_ v:SIMD2<Float>)->Float { u.x*v.y-u.y*v.x }
            let d=cross(b-a,c-a)
            guard abs(d)>0.000001 else { continue }
            let u=cross(point-a,c-a)/d,v=cross(b-a,point-a)/d
            if u >= -0.001 && v >= -0.001 && u+v<=1.001 { return true }
        }
        return false
    }
    static func fitsWall(width:Float,height:Float,triangles:[SIMD2<Float>])->Bool {
        // No guessed rectangle spanning an opening: every sampled part needs wall.
        let boundary=outline(width:width+0.10,height:height+0.10)
        return [Float(0),0.4,0.75,1].allSatisfy { radius in
            boundary.allSatisfy { contains($0*radius,triangles:triangles) }
        }
    }
}
