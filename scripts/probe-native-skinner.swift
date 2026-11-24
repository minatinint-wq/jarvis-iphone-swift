import Foundation
import SceneKit
import AppKit
import Metal

func matrix(_ values:[Double])->simd_float4x4 {
    let v=values.map(Float.init)
    return simd_float4x4(SIMD4(v[0],v[1],v[2],v[3]),SIMD4(v[4],v[5],v[6],v[7]),SIMD4(v[8],v[9],v[10],v[11]),SIMD4(v[12],v[13],v[14],v[15]))
}

// A short compatibility probe for SceneKit, independent of the simulator build.
let resources=URL(fileURLWithPath:CommandLine.arguments[1])
let assets=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("SPATIAL_ASSETS.json"))) as! [[String:Any]]
var checked=0
let output=URL(fileURLWithPath:CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "/tmp/rig-previews")
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
guard let device=MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
for asset in assets where (asset["id"] as! String).hasPrefix("animated_") {
    let rig=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent(asset["rig"] as! String))) as! [String:Any]
    let count=(rig["bones"] as! [[String:Any]]).count
    let skeletonSpec=rig["bones"] as! [[String:Any]],root=SCNNode(),skeleton=SCNNode()
    root.addChildNode(skeleton)
    let bones=(0..<count).map { _ in SCNNode() }
    for i in 0..<count {
        bones[i].simdTransform=matrix(skeletonSpec[i]["local"] as! [Double])
        let parent=skeletonSpec[i]["parent"] as! Int
        (parent<0 ? skeleton : bones[parent]).addChildNode(bones[i])
    }
    let inverse=skeletonSpec.map { NSValue(scnMatrix4:SCNMatrix4(matrix($0["inverseBind"] as! [Double]))) }
    var minimum=Float.infinity,maximum = -Float.infinity
    for part in asset["parts"] as! [[String:Any]] {
        let mesh=try Data(contentsOf:resources.appendingPathComponent(part["mesh"] as! String))
        let vertices=Int(mesh.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:UInt32.self) })
        let positions=SCNGeometrySource(data:mesh,semantic:.vertex,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:12,dataStride:32)
        let normals=SCNGeometrySource(data:mesh,semantic:.normal,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:24,dataStride:32)
        let uv=SCNGeometrySource(data:mesh,semantic:.texcoord,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:36,dataStride:32)
        let faces=Int(mesh.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:8,as:UInt32.self) })
        let geometry=SCNGeometry(sources:[positions,normals,uv],elements:[SCNGeometryElement(data:mesh.suffix(faces*12),primitiveType:.triangles,primitiveCount:faces,bytesPerIndex:4)])
        let material=SCNMaterial();material.lightingModel = .physicallyBased
        if let c=part["baseColor"] as? [Double] { material.diffuse.contents=NSColor(red:c[0],green:c[1],blue:c[2],alpha:c[3]) }
        if let file=part["Color"] as? String { material.diffuse.contents=NSImage(contentsOf:resources.appendingPathComponent(file)) }
        material.roughness.contents=part["roughness"] ?? 0.8;geometry.materials=[material]
        let skin=try Data(contentsOf:resources.appendingPathComponent(part["skin"] as! String))
        var indices=Data(),weights=Data()
        for vertex in 0..<vertices {
            for j in 0..<4 { indices.append(skin[vertex*20+j]);indices.append(0) }
            weights.append(skin.subdata(in:(vertex*20+4)..<(vertex*20+20)))
        }
        let indexSource=SCNGeometrySource(data:indices,semantic:.boneIndices,vectorCount:vertices,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
        let weightSource=SCNGeometrySource(data:weights,semantic:.boneWeights,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let node=SCNNode(geometry:geometry)
        node.skinner=SCNSkinner(baseGeometry:geometry,bones:bones,boneInverseBindTransforms:inverse,boneWeights:weightSource,boneIndices:indexSource)
        node.skinner?.skeleton=skeleton;root.addChildNode(node)
        precondition(node.skinner?.bones.count == count,"SceneKit refused packed skeletal sources")
        checked+=1
        // Check the grounded idle pose mathematically using the packaged weights.
        let animations=rig["animations"] as! [[String:Any]]
        let idle=animations.first { $0["name"] as! String == "Idle" }
        if let frame=(idle?["frames"] as? [[[Double]]])?.first {
            var world:[simd_float4x4]=[]
            for i in 0..<count {
                let m=matrix(frame[i]),parent=skeletonSpec[i]["parent"] as! Int
                world.append(parent<0 ? m : world[parent]*m)
            }
            for vertex in 0..<vertices {
                let p:SIMD4<Float>=mesh.withUnsafeBytes { bytes in SIMD4(bytes.loadUnaligned(fromByteOffset:12+vertex*32,as:Float.self),bytes.loadUnaligned(fromByteOffset:16+vertex*32,as:Float.self),bytes.loadUnaligned(fromByteOffset:20+vertex*32,as:Float.self),1) }
                var result=SIMD4<Float>.zero
                for j in 0..<4 {
                    let index=Int(skin[vertex*20+j]),weight=skin.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:vertex*20+4+j*4,as:Float.self) }
                    result += (world[index]*matrix(skeletonSpec[index]["inverseBind"] as! [Double])*p)*weight
                }
                minimum=min(minimum,result.y);maximum=max(maximum,result.y)
            }
        }
    }
    let robot=asset["id"] as! String == "animated_robot"
    if robot { precondition(abs(minimum)<0.01 && maximum-minimum>1.5 && maximum-minimum<1.9,"Robot feet must rest on its physical anchor") }
    for (variant,fraction) in [0.0,0.65].enumerated() {
        let clips=rig["animations"] as! [[String:Any]],clip=clips.first { $0["name"] as! String == (robot ? "Wave" : "Run") }!
        let frames=clip["frames"] as! [[[Double]]],frame=frames[Int(Double(frames.count-1)*fraction)]
        for i in 0..<count { bones[i].simdTransform=matrix(frame[i]) }
        let scene=SCNScene();scene.background.contents=NSColor(white:0.06,alpha:1);scene.rootNode.addChildNode(root)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.fieldOfView=50
        camera.position=robot ? SCNVector3(2.2,1.5,3.2) : SCNVector3(0.9,0.65,1.1)
        camera.look(at:robot ? SCNVector3(0,0.85,0) : SCNVector3(0,0.22,0));scene.rootNode.addChildNode(camera)
        let light=SCNNode();light.light=SCNLight();light.light?.type = .directional;light.light?.intensity=1000;light.eulerAngles=SCNVector3(-0.7,-0.4,0);scene.rootNode.addChildNode(light)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=550;scene.rootNode.addChildNode(ambient)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:CGSize(width:500,height:400),antialiasingMode:.multisampling4X)
        let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try png.write(to:output.appendingPathComponent((asset["id"] as! String)+"-\(variant).png"))
        root.removeFromParentNode()
    }
}
print("NATIVE_SKINNER_OK parts=\(checked)")
