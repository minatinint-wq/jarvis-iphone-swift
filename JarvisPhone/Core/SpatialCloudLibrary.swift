import Foundation
import CryptoKit
import SwiftUI

@MainActor final class SpatialCloudLibrary:ObservableObject {
    static let shared=SpatialCloudLibrary()
    static let origin=URL(string:"https://jarvis-spatial-library.minatinint.workers.dev")!
    @Published private(set) var status="Modelos locais prontos."
    @Published private(set) var models:[[String:Any]]=[]
    private var installed:[String:URL]=[:]
    private var checked=Set<String>()
    private var refreshed=Date.distantPast
    private let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SpatialCloud",isDirectory:true)
    static func valid(_ spec:[String:Any])->Bool {
        guard let id=spec["id"] as? String,id.range(of:#"^[a-z0-9_]{1,64}$"#,options:.regularExpression) != nil,
              let title=spec["title"] as? String,!title.isEmpty,title.count<=120,
              let triangles=spec["triangles"] as? Int,(1...350000).contains(triangles),
              let files=spec["files"] as? [[String:Any]],!files.isEmpty,files.count<=180 else { return false }
        var names=Set<String>(),total=0
        for f in files {
            guard let name=f["file"] as? String,name==URL(fileURLWithPath:name).lastPathComponent,name.hasPrefix("Spatial_"+id),
                  ["mesh","skin","json","jpg","png","texture"].contains(URL(fileURLWithPath:name).pathExtension),names.insert(name).inserted,
                  let bytes=f["bytes"] as? Int,(1...25*1024*1024).contains(bytes),let hash=f["sha256"] as? String,
                  hash.count==64,hash.allSatisfy({$0.isHexDigit}) else { return false }
            total+=bytes
        }
        return total<=100*1024*1024
    }
    func refresh(force:Bool=false) async {
        guard force || Date().timeIntervalSince(refreshed)>300 else { return }
        do {
            var request=URLRequest(url:Self.origin.appendingPathComponent("catalog.json"));request.timeoutInterval=15
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200,data.count<2*1024*1024,
                  let body=try JSONSerialization.jsonObject(with:data) as? [String:Any],body["version"] as? Int==1,
                  let specs=body["models"] as? [[String:Any]],specs.count<=150 else { throw CocoaError(.fileReadCorruptFile) }
            models=specs.filter(Self.valid);refreshed=Date();status="\(models.count) modelos na biblioteca."
        } catch { status="Biblioteca sem conexão. Os modelos locais continuam disponíveis." }
    }
    func spec(_ id:String)->[String:Any]? { models.first{$0["id"] as? String==id} }
    func file(_ name:String)->URL? { installed[name] }
    func ensure(_ id:String) async throws {
        if checked.contains(id) { return }
        if models.isEmpty { await refresh() }
        guard let spec=spec(id),Self.valid(spec),let files=spec["files"] as? [[String:Any]] else { throw CocoaError(.fileNoSuchFile) }
        let hashes=files.compactMap{$0["sha256"] as? String}.joined(),version=SHA256.hash(data:Data(hashes.utf8)).map{String(format:"%02x",$0)}.joined()
        let folder=root.appendingPathComponent(id,isDirectory:true).appendingPathComponent(version,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var verified:[String:URL]=[:]
        for (index,f) in files.enumerated() {
            try Task.checkCancellation()
            let name=f["file"] as! String,hash=f["sha256"] as! String,size=f["bytes"] as! Int,dest=folder.appendingPathComponent(name)
            func validFile()->Bool {
                guard let bytes=try? Data(contentsOf:dest),bytes.count==size else { return false }
                return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()==hash
            }
            if !validFile() {
                status="Baixando \(spec["title"] as? String ?? id) · \(index+1)/\(files.count)"
                var request=URLRequest(url:Self.origin.appendingPathComponent("assets").appendingPathComponent(hash).appendingPathComponent(name));request.timeoutInterval=45
                let (temporary,response)=try await URLSession.shared.download(for:request)
                defer { try? FileManager.default.removeItem(at:temporary) }
                guard (response as? HTTPURLResponse)?.statusCode==200,let count=try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize,count==size else { throw CocoaError(.fileReadCorruptFile) }
                let data=try Data(contentsOf:temporary)
                guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==hash else { throw CocoaError(.fileReadCorruptFile) }
                try data.write(to:dest,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
            verified[name]=dest
        }
        installed.merge(verified){_,new in new};checked.insert(id);status="Modelo pronto. Aponte para uma superfície livre."
    }
}
