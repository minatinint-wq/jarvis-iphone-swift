import Foundation
import SceneKit

// A short compatibility probe for SceneKit, independent of the simulator build.
let resources=URL(fileURLWithPath:CommandLine.arguments[1])
let assets=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("SPATIAL_ASSETS.json"))) as! [[String:Any]]
var checked=0
for asset in assets where (asset["id"] as! String).hasPrefix("animated_") {
    let rig=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent(asset["rig"] as! String))) as! [String:Any]
    let count=(rig["bones"] as! [[String:Any]]).count
    for part in asset["parts"] as! [[String:Any]] {
        let mesh=try Data(contentsOf:resources.appendingPathComponent(part["mesh"] as! String))
        let vertices=Int(mesh.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:UInt32.self) })
        let positions=SCNGeometrySource(data:mesh,semantic:.vertex,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:12,dataStride:32)
        let geometry=SCNGeometry(sources:[positions],elements:[])
        let skin=try Data(contentsOf:resources.appendingPathComponent(part["skin"] as! String))
        var indices=Data(),weights=Data()
        for vertex in 0..<vertices {
            for j in 0..<4 { indices.append(skin[vertex*20+j]);indices.append(0) }
            weights.append(skin.subdata(in:(vertex*20+4)..<(vertex*20+20)))
        }
        let indexSource=SCNGeometrySource(data:indices,semantic:.boneIndices,vectorCount:vertices,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
        let weightSource=SCNGeometrySource(data:weights,semantic:.boneWeights,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let bones=(0..<count).map { _ in SCNNode() }
        let node=SCNNode(geometry:geometry)
        node.skinner=SCNSkinner(baseGeometry:geometry,bones:bones,boneInverseBindTransforms:bones.map { _ in NSValue(scnMatrix4:SCNMatrix4Identity) },boneWeights:weightSource,boneIndices:indexSource)
        precondition(node.skinner?.bones.count == count,"SceneKit refused packed skeletal sources")
        checked+=1
    }
}
print("NATIVE_SKINNER_OK parts=\(checked)")
