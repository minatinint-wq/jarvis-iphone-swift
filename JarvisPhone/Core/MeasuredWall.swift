import Foundation
import simd

/// Coordinates are meters in the selected wall's frame, never screen pixels.
struct WallOpening: Equatable {
    let low: SIMD2<Float>
    let high: SIMD2<Float>
    init(_ a: SIMD2<Float>, _ b: SIMD2<Float>, margin: Float = 0.015) {
        low = simd_min(a,b) - SIMD2<Float>(repeating:margin)
        high = simd_max(a,b) + SIMD2<Float>(repeating:margin)
    }
    var corners: [SIMD2<Float>] { [low,.init(high.x,low.y),high,.init(low.x,high.y)] }
    func contains(_ p: SIMD2<Float>) -> Bool { p.x >= low.x && p.x <= high.x && p.y >= low.y && p.y <= high.y }
}

enum MeasuredWall {
    static func area(_ p: [SIMD2<Float>]) -> Float {
        guard p.count >= 3 else { return 0 }
        return abs(p.indices.reduce(Float(0)) { $0 + WallBoundary.cross(p[$1],p[($1+1)%p.count]) })/2
    }
    static func valid(_ p: [SIMD2<Float>]) -> Bool {
        guard (3...12).contains(p.count), p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), area(p) >= 0.02 else { return false }
        // Reject bow ties and crossing edges before triangulation or approval.
        for i in p.indices {
            let a=p[i], b=p[(i+1)%p.count]
            guard simd_distance(a,b) >= 0.02 else { return false }
            for j in p.indices where j>i+1 && !(i==0 && j==p.count-1) {
                let c=p[j], d=p[(j+1)%p.count]
                if WallBoundary.cross(b-a,c-a)*WallBoundary.cross(b-a,d-a) <= 0 &&
                    WallBoundary.cross(d-c,a-c)*WallBoundary.cross(d-c,b-c) <= 0 { return false }
            }
        }
        return !WallBoundary.triangles(p).isEmpty
    }
    /// Sutherland-Hodgman for one half plane, preserving exact cut boundaries.
    static func clip(_ p: [SIMD2<Float>], normal: SIMD2<Float>, offset: Float) -> [SIMD2<Float>] {
        guard var a=p.last else { return [] }; var result: [SIMD2<Float>] = []
        for b in p {
            let da=simd_dot(normal,a)+offset, db=simd_dot(normal,b)+offset
            if (da>=0) != (db>=0) { result.append(a+(b-a)*(da/(da-db))) }
            if db>=0 { result.append(b) }; a=b
        }
        return result
    }
    /// Subtract each opening from each triangle. No centroid-only masks: a large
    /// triangle spanning a doorway must be split, even if its centroid is outside.
    static func cut(_ triangles: [[SIMD2<Float>]], openings: [WallOpening]) -> [[SIMD2<Float>]] {
        var polygons=triangles
        for hole in openings {
            let edges: [(SIMD2<Float>,Float)] = [(.init(1,0),-hole.low.x),(.init(-1,0),hole.high.x),(.init(0,1),-hole.low.y),(.init(0,-1),hole.high.y)]
            var next: [[SIMD2<Float>]]=[]
            for polygon in polygons {
                var inside=polygon
                for (n,d) in edges {
                    let outside=clip(inside,normal:-n,offset:-d)
                    if area(outside)>0.000001 { next.append(outside) }
                    inside=clip(inside,normal:n,offset:d)
                    if inside.count<3 { break }
                }
            }
            polygons=next
        }
        return polygons.flatMap { polygon -> [[SIMD2<Float>]] in
            guard polygon.count>=3 else { return [] }
            return (1..<(polygon.count-1)).map { [polygon[0],polygon[$0],polygon[$0+1]] }.filter { area($0)>0.000001 }
        }
    }
    static func triangles(_ outline: [SIMD2<Float>], excluding holes: [WallOpening]) -> [[SIMD2<Float>]] {
        let indices=WallBoundary.triangles(outline)
        let source=stride(from:0,to:indices.count,by:3).map { i in (0..<3).map { outline[Int(indices[i+$0])] } }
        return cut(source,openings:holes)
    }
    static func contains(_ p: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count>=3 else { return false }; var inside=false; var j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i], b=polygon[j]
            if (a.y>p.y) != (b.y>p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }; j=i
        }
        return inside
    }
}
