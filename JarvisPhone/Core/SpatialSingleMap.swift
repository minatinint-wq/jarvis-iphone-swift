import Foundation

enum SpatialSingleMap {
    static let migrationKey="jarvis.ar.singleMap.v37"
    static func isMapArtifact(_ name:String)->Bool {
        let base=name.hasSuffix(".mapinfo") ? String(name.dropLast(8)) : name
        return base=="home.json" || (base.hasPrefix("home-") && base.hasSuffix(".json"))
    }
    /// Only regular map files directly inside the app's dedicated directory.
    /// Never traverse a subdirectory or a symbolic link; scans/diagnostics stay.
    @discardableResult static func prune(at file:URL,preserveCurrent:Bool)throws->Int {
        let fm=FileManager.default,root=file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath:root.path) else { return 0 }
        let entries=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        var removed=0
        for entry in entries where isMapArtifact(entry.lastPathComponent) {
            guard entry.standardizedFileURL.deletingLastPathComponent()==root else { continue }
            if preserveCurrent,[file.lastPathComponent,file.lastPathComponent+".mapinfo"].contains(entry.lastPathComponent) { continue }
            let values=try entry.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true else { continue }
            try fm.removeItem(at:entry);removed+=1
        }
        return removed
    }
    @discardableResult static func migrate(at file:URL,defaults:UserDefaults = .standard)throws->Int {
        guard !defaults.bool(forKey:migrationKey) else { return 0 }
        let count=try prune(at:file,preserveCurrent:false)
        defaults.set(count,forKey:migrationKey+".removed")
        defaults.set(true,forKey:migrationKey)
        return count
    }
}
