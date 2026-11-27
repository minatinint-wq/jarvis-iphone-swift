import Foundation
import ARKit
import CoreLocation

/// GPS selects a site, never the pose of an object inside a room.
struct SpatialMapLocation:Codable,Equatable {
    var latitude:Double
    var longitude:Double
    var accuracy:Double
    var timestamp:Date
    var valid:Bool { latitude.isFinite && longitude.isFinite && accuracy.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) && (0...5000).contains(accuracy) }
    func distance(to other:Self)->Double {
        CLLocation(latitude:latitude,longitude:longitude).distance(from:CLLocation(latitude:other.latitude,longitude:other.longitude))
    }
    func separation(from other:Self)->Double? {
        guard valid,other.valid,accuracy<=100,other.accuracy<=100 else { return nil }
        return max(0,distance(to:other)-accuracy-other.accuracy)
    }
}

struct SpatialMapSummary:Codable {
    var world:UUID
    var saved:Date
    var location:SpatialMapLocation?
}

struct SpatialScannedRoomRecord:Codable {
    var anchor:UUID
    var transform:[Float]
    var sourceSHA256:String
    var plane:Int? = nil
    var style:String = "white"
    var forest:Bool? = nil
}

enum SpatialRoomAlignment {
    /// Metric registration on the floor. Scale and gravity are never guessed.
    static func fit(source:[SIMD3<Float>],target:[SIMD3<Float>])->simd_float4x4? {
        guard source.count==3,target.count==3,(source+target).allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) else { return nil }
        for points in [source,target] {
            let a=points[1]-points[0],b=points[2]-points[0]
            guard abs(a.x*b.z-a.z*b.x)>0.12,(points.map(\.y).max()! - points.map(\.y).min()!)<0.16 else { return nil }
        }
        for a in 0..<3 { for b in (a+1)..<3 {
            let s=simd_distance(source[a],source[b]),t=simd_distance(target[a],target[b])
            guard s>0.4,abs(s-t)<max(0.08,s*0.06) else { return nil }
        } }
        let sc=source.reduce(.zero,+)/3,tc=target.reduce(.zero,+)/3
        var dot:Float=0,cross:Float=0
        for i in 0..<3 { let s=source[i]-sc,t=target[i]-tc;dot+=s.x*t.x+s.z*t.z;cross+=s.z*t.x-s.x*t.z }
        var pose=simd_float4x4(simd_quatf(angle:atan2(cross,dot),axis:SIMD3(0,1,0)))
        let rotated=pose*SIMD4(sc,1);pose.columns.3=SIMD4(tc.x-rotated.x,tc.y-rotated.y,tc.z-rotated.z,1)
        for i in 0..<3 { let p=pose*SIMD4(source[i],1);guard simd_distance(SIMD3(p.x,p.y,p.z),target[i])<0.10 else { return nil } }
        return pose
    }
}

/// A connected desktop is an active tool, including when an older map predates it.
struct SpatialDesktopResumeIntent {
    private(set) var pending=false
    mutating func prepare(wasOpen:Bool,savedWindow:Bool) { pending=wasOpen && !savedWindow }
    mutating func consume(cameraStable:Bool,savedWindowPending:Bool)->Bool {
        guard pending,cameraStable,!savedWindowPending else { return false }
        pending=false;return true
    }
}

struct SpatialLocalizationReadiness {
    var cameraStable:Bool
    var pendingObjects:Int
    var pendingPanel:Bool
    var pendingDesktop:Bool
    var localized:Bool { cameraStable && pendingObjects == 0 && !pendingPanel && !pendingDesktop }
    var desktopReady:Bool { cameraStable && !pendingDesktop }
    var panelReady:Bool { cameraStable && !pendingPanel }
}

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
    var supportTransform: [Float]? = nil
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
    var location:SpatialMapLocation? = nil
    var scannedRoom:SpatialScannedRoomRecord? = nil
    var portal:SpatialPortalRecord? = nil

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
            if let support=object.supportTransform,Self.matrix(support) == nil { throw CocoaError(.fileReadCorruptFile) }
        }
        if let panel {
            guard panel.scale.isFinite, (0.20...0.70).contains(panel.scale) else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let desktop {
            guard desktop.scale.isFinite,(0.25...2).contains(desktop.scale) else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let portal,!portal.valid { throw CocoaError(.fileReadCorruptFile) }
        if let location,!location.valid { throw CocoaError(.fileReadCorruptFile) }
        if let scannedRoom {
            guard Self.matrix(scannedRoom.transform) != nil,scannedRoom.sourceSHA256.count==64,
                  scannedRoom.sourceSHA256.allSatisfy({$0.isHexDigit}),["white","brick"].contains(scannedRoom.style),
                  scannedRoom.plane.map({$0>=0 && $0<64}) ?? true else { throw CocoaError(.fileReadCorruptFile) }
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
    static func savedMaps() -> [URL] {
        let directory=file.deletingLastPathComponent()
        let entries=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        return entries.filter { $0.lastPathComponent == "home.json" || ($0.lastPathComponent.hasPrefix("home-") && $0.pathExtension == "json") }
            .sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    static func savedMaps(near location:SpatialMapLocation?,candidates:[URL]? = nil)->[URL] {
        let files=candidates ?? savedMaps()
        guard let location else { return files }
        let ranked=files.enumerated().map { index,url -> (URL,Double,Int) in
            let metadata=try? JSONDecoder().decode(SpatialMapSummary.self,from:Data(contentsOf:url.appendingPathExtension("mapinfo")))
            let gap=metadata?.location.flatMap { location.separation(from:$0) }
            return (url,gap ?? .infinity,index)
        }
        return ranked.sorted { $0.1 == $1.1 ? $0.2<$1.2 : $0.1<$1.1 }.map{$0.0}
    }

    /// Switch only after validating the chosen archive; serialize calls with saves.
    /// Keep the previous map as an individually restorable file.
    static func activate(_ source: URL?,at file: URL = Self.file,keepPrevious:Bool=true) throws {
        let archive: SpatialArchive?
        if let source {
            guard let saved=try load(from:source) else { throw CocoaError(.fileNoSuchFile) }
            archive=saved
        } else { archive=nil }
        if !keepPrevious { try SpatialSingleMap.prune(at:file,preserveCurrent:source==file) }
        if keepPrevious,source != file,FileManager.default.fileExists(atPath:file.path) {
            let backup=file.deletingLastPathComponent().appendingPathComponent("home-"+UUID().uuidString+".json")
            try FileManager.default.moveItem(at:file,to:backup)
            let info=file.appendingPathExtension("mapinfo")
            if FileManager.default.fileExists(atPath:info.path) { try? FileManager.default.moveItem(at:info,to:backup.appendingPathExtension("mapinfo")) }
        }
        if source != file,let archive { try archive.write(to:file) }
    }

    func write(to file: URL = Self.file,singleMap:Bool=false) throws {
        try validate()
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(self).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        let metadata=SpatialMapSummary(world:world,saved:saved,location:location)
        try? JSONEncoder().encode(metadata).write(to:file.appendingPathExtension("mapinfo"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        if singleMap { try SpatialSingleMap.prune(at:file,preserveCurrent:true) }
        var directory = file.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}

/// Observations outside the current camera view preserve previous evidence.
/// A resumed session starts with no evidence, even if the camera reports normal.
struct SpatialSupportProof {
    private var consecutive=0
    private(set) var confirmed: Bool
    init(confirmed: Bool = false) { self.confirmed=confirmed }
    mutating func observe(matches: Int,conflicts: Int) {
        if conflicts>=2 { consecutive=0;confirmed=false }
        else if matches>=3 {
            consecutive=min(2,consecutive+1)
            confirmed = confirmed || consecutive>=2
        } else { consecutive=0 }
    }
}
