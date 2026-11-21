import Foundation
import simd

/// Inward-facing line in wall-local meters: dot(normal, point) + offset >= 0.
struct WallEdge {
    let normal: SIMD2<Float>
    let offset: Float
    let ceiling: Bool
    func distance(_ p: SIMD2<Float>) -> Float { simd_dot(normal,p)+offset }
}

enum WallBoundary {
    static func fitted(_ source: [SIMD2<Float>], edges: [WallEdge]) -> [SIMD2<Float>] {
        var polygon = source
        for edge in edges {
            guard polygon.count >= 3 else { return [] }
            var result: [SIMD2<Float>] = []
            var a = polygon.last!
            for b in polygon {
                let da = edge.distance(a), db = edge.distance(b)
                if (da >= 0) != (db >= 0) { result.append(a+(b-a)*(da/(da-db))) }
                if db >= 0 { result.append(b) }
                a = b
            }
            polygon = result
        }
        // Close only small measured gaps. Never stretch a partial scan meters
        // toward an assumed ceiling. Two passes join perpendicular corners.
        for _ in 0..<2 {
            polygon = polygon.map { point in
                var p = point
                for edge in edges {
                    let d = edge.distance(p)
                    if abs(d) <= (edge.ceiling ? 0.35 : 0.15) { p -= edge.normal*d }
                }
                return p
            }
        }
        var clean: [SIMD2<Float>] = []
        for p in polygon where p.x.isFinite && p.y.isFinite {
            if let last = clean.last, simd_distance(last,p) < 0.003 { continue }
            clean.append(p)
        }
        if clean.count > 2, simd_distance(clean[0],clean.last!) < 0.003 { clean.removeLast() }
        return clean
    }
    static func touchesCeiling(_ polygon: [SIMD2<Float>], edges: [WallEdge]) -> Bool {
        edges.contains { edge in edge.ceiling && polygon.filter { abs(edge.distance($0)) < 0.02 }.count >= 2 }
    }
    static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x*b.y-a.y*b.x }
    /// Ear clipping preserves concave measured outlines. Never fill the bounding box.
    static func triangles(_ polygon: [SIMD2<Float>]) -> [UInt32] {
        guard polygon.count >= 3 else { return [] }
        let area = polygon.indices.reduce(Float(0)) { $0 + cross(polygon[$1],polygon[($1+1)%polygon.count]) }
        guard abs(area) > 0.01 else { return [] }
        var remaining = area > 0 ? Array(polygon.indices) : Array(polygon.indices.reversed())
        var result: [UInt32] = []
        var budget = polygon.count*polygon.count
        while remaining.count > 3 && budget > 0 {
            budget -= 1
            var removed = false
            for i in remaining.indices {
                let ai = remaining[(i+remaining.count-1)%remaining.count], bi = remaining[i], ci = remaining[(i+1)%remaining.count]
                let a = polygon[ai], b = polygon[bi], c = polygon[ci]
                let turn = cross(b-a,c-b)
                if abs(turn) < 0.000001 { remaining.remove(at:i); removed = true; break }
                guard turn > 0 else { continue }
                let blocked = remaining.contains { j in
                    guard j != ai, j != bi, j != ci else { return false }
                    let p = polygon[j]
                    return cross(b-a,p-a) >= -0.000001 && cross(c-b,p-b) >= -0.000001 && cross(a-c,p-c) >= -0.000001
                }
                if !blocked {
                    result += [UInt32(ai),UInt32(bi),UInt32(ci)]
                    remaining.remove(at:i); removed = true; break
                }
            }
            if !removed { return [] }
        }
        guard remaining.count == 3 else { return [] }
        result += remaining.map(UInt32.init)
        return result
    }
}
