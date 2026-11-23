import Foundation
import simd

enum WallDepthReading { case wall, obstacle, unknown, outside }
struct WallDepthEvidence {
    private var confirmations: [Int:Int] = [:]
    mutating func observe(_ readings: [WallDepthReading]) -> [Int] {
        var visible: [Int]=[]
        for (id,value) in readings.enumerated() {
            switch value {
            case .wall: confirmations[id]=min(2,(confirmations[id] ?? 0)+1)
            case .obstacle,.unknown: confirmations[id]=0
            case .outside: break // retain only previously observed surface, never invent it
            }
            if confirmations[id] == 2 { visible.append(id) }
        }
        return visible
    }
    static func classify(expected: Float, measured: Float, confidence: UInt8) -> WallDepthReading {
        guard expected.isFinite, measured.isFinite, expected>0.2, expected<4.5,
              measured>0.1, confidence>=2 else { return .unknown }
        if measured<expected-0.07 { return .obstacle }
        return abs(measured-expected)<=0.07 ? .wall : .unknown
    }
    /// Small triangles let depth reject foreground furniture locally. Subdivision
    /// is geometry-only, with a strict budget, performed outside the render loop.
    static func subdivide(_ triangles: [[SIMD2<Float>]], limit: Int = 18000) -> [[SIMD2<Float>]] {
        var pending=triangles, result: [[SIMD2<Float>]]=[]
        while let t=pending.popLast() {
            let lengths=[simd_distance(t[0],t[1]),simd_distance(t[1],t[2]),simd_distance(t[2],t[0])]
            let edge=lengths.indices.max(by:{ lengths[$0]<lengths[$1] })!
            if lengths[edge]>0.14 && result.count+pending.count+2<limit {
                let a=t[edge], b=t[(edge+1)%3], c=t[(edge+2)%3], mid=(a+b)/2
                pending.append([a,mid,c]);pending.append([mid,b,c])
            } else { result.append(t) }
        }
        return result
    }
}
