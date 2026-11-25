import Foundation

@main struct SingleMapProbe {
    static func main()throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("jarvis-map-probe-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false)
        precondition(root.deletingLastPathComponent().standardizedFileURL==fm.temporaryDirectory.standardizedFileURL)
        defer { try? fm.removeItem(at:root) }
        let file=root.appendingPathComponent("home.json")
        for name in ["home.json","home.json.mapinfo","home-old.json","home-old.json.mapinfo","scan.glb","diagnostics.json"] {
            try Data(name.utf8).write(to:root.appendingPathComponent(name))
        }
        let nested=root.appendingPathComponent("home-directory.json",isDirectory:true)
        try fm.createDirectory(at:nested,withIntermediateDirectories:false)
        try Data("untouched".utf8).write(to:nested.appendingPathComponent("home.json"))
        let link=root.appendingPathComponent("home-link.json")
        try fm.createSymbolicLink(at:link,withDestinationURL:root.appendingPathComponent("scan.glb"))
        let oldBackups=try SpatialSingleMap.prune(at:file,preserveCurrent:true);precondition(oldBackups==2)
        precondition(fm.fileExists(atPath:file.path))
        let oldCurrent=try SpatialSingleMap.prune(at:file,preserveCurrent:false);precondition(oldCurrent==2)
        for name in ["scan.glb","diagnostics.json","home-directory.json/home.json","home-link.json"] { precondition(fm.fileExists(atPath:root.appendingPathComponent(name).path),name) }
        let suite="jarvis.map.probe."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        try Data("legacy".utf8).write(to:file)
        let first=try SpatialSingleMap.migrate(at:file,defaults:defaults);precondition(first==1)
        try Data("current-map".utf8).write(to:file)
        let second=try SpatialSingleMap.migrate(at:file,defaults:defaults);precondition(second==0)
        let current=try Data(contentsOf:file);precondition(current==Data("current-map".utf8))
        print("Single-map cleanup passed: current map preserved, legacy maps removed, scans/directories/symlinks untouched, migration runs once.")
    }
}
