import Foundation
import ARKit

struct SpatialRoom: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var origin: [Float]
}

struct SpatialObjectRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var model: String
    var room: UUID
    var anchor: UUID
    var localTransform: [Float]
    var scale: Float
    var updated: Date
    var kind: String = "object"
    var persistence: String = "anchored"
}

struct SpatialPanelRecord: Codable {
    var anchor: UUID
    var module: String
    var scale: Float
}

/// One atomic file couples the map and transforms from the same session revision.
/// Replacing a snapshot cannot leave a new scene paired with an old world map.
struct SpatialArchive: Codable {
    var version = 1
    var world: UUID
    var rooms: [SpatialRoom]
    var objects: [SpatialObjectRecord]
    var panel: SpatialPanelRecord?
    var desktop: SpatialDesktopRecord? = nil
    var map: Data
    var saved: Date

    func validate() throws {
        guard version == 1, !rooms.isEmpty, rooms.count <= 32, objects.count <= 6,
              Set(rooms.map(\.id)).count == rooms.count,
              Set(objects.map(\.id)).count == objects.count,
              Set(objects.map(\.anchor)).count == objects.count,
              !map.isEmpty, map.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        for room in rooms {
            guard !room.name.isEmpty, room.name.count <= 80,
                  Self.matrix(room.origin) != nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        for object in objects {
            guard rooms.contains(where: { $0.id == object.room }),
                  Self.matrix(object.localTransform) != nil,
                  object.scale.isFinite, (0.25...2).contains(object.scale),
                  !object.model.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let panel {
            guard panel.scale.isFinite, (0.20...0.70).contains(panel.scale) else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let desktop {
            guard desktop.scale.isFinite,(0.25...2).contains(desktop.scale) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    static func values(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { c in (0..<4).map { m[c][$0] } }
    }

    static func matrix(_ a: [Float]) -> simd_float4x4? {
        guard a.count == 16, a.allSatisfy(\.isFinite) else { return nil }
        let m = simd_float4x4(SIMD4(a[0],a[1],a[2],a[3]), SIMD4(a[4],a[5],a[6],a[7]),
                             SIMD4(a[8],a[9],a[10],a[11]), SIMD4(a[12],a[13],a[14],a[15]))
        guard abs(simd_determinant(m) - 1) < 0.01, abs(m[3][3] - 1) < 0.001,
              abs(m[0][3]) + abs(m[1][3]) + abs(m[2][3]) < 0.001 else { return nil }
        for c in 0..<3 {
            let v = SIMD3(m[c].x,m[c].y,m[c].z)
            guard abs(simd_length(v) - 1) < 0.01 else { return nil }
        }
        return m
    }

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisSpatial", isDirectory: true).appendingPathComponent("home.json")
    }

    static func load(from file: URL = Self.file) throws -> Self? {
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 90 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let archive = try JSONDecoder().decode(Self.self, from:Data(contentsOf:file))
        try archive.validate()
        return archive
    }

    func write(to file: URL = Self.file) throws {
        try validate()
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(self).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        var directory = file.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
