import SceneKit
import SwiftUI

/// Native skeletal animation. Source GLB rigs are converted offline in Blender.
/// Each instance has its own joints and skinner; immutable resource data is shared.
@MainActor enum SpatialRig {
    struct Bone: Decodable {
        let name: String
        let parent: Int
        let local: [Float]
        let inverseBind: [Float]
    }
    struct Clip: Decodable {
        let name: String
        let duration: Double
        let frames: [[[Float]]]
    }
    struct Spec: Decodable {
        let heightMeters: Float
        let bones: [Bone]
        let animations: [Clip]
    }
    static let identifiers=["animated_robot","animated_fox"]
    private static var specs: [String:Spec]=[:]

    static func matrix(_ values: [Float]) throws -> simd_float4x4 {
        guard values.count==16,values.allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
        let m=simd_float4x4(SIMD4(values[0],values[1],values[2],values[3]),SIMD4(values[4],values[5],values[6],values[7]),
                            SIMD4(values[8],values[9],values[10],values[11]),SIMD4(values[12],values[13],values[14],values[15]))
        guard abs(simd_determinant(m))>0.00000001,abs(values[15]-1)<0.001 else { throw CocoaError(.fileReadCorruptFile) }
        return m
    }

    static func load(id: String,entry: [String:Any]) throws -> SCNNode {
        guard identifiers.contains(id),let file=entry["rig"] as? String,let url=Bundle.main.url(forResource:file,withExtension:nil),
              let parts=entry["parts"] as? [[String:Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let spec: Spec
        if let cached=specs[id] { spec=cached }
        else {
            spec=try JSONDecoder().decode(Spec.self,from:Data(contentsOf:url))
            guard !spec.bones.isEmpty,spec.bones.count<256,spec.animations.count<=12 else { throw CocoaError(.fileReadCorruptFile) }
            for clip in spec.animations {
                guard clip.duration>0,clip.duration<30,clip.frames.count>=2,clip.frames.count<=400,
                      clip.frames.allSatisfy({ $0.count==spec.bones.count }) else { throw CocoaError(.fileReadCorruptFile) }
                for frame in clip.frames { for pose in frame { _=try matrix(pose) } }
            }
            specs[id]=spec
        }
        let root=SCNNode();root.name="rig:"+id
        let skeleton=SCNNode();skeleton.name="rig-skeleton";root.addChildNode(skeleton)
        let joints=try spec.bones.enumerated().map { index,bone -> SCNNode in
            let joint=SCNNode();joint.name="rig-joint-\(index)";joint.simdTransform=try matrix(bone.local);return joint
        }
        for (index,bone) in spec.bones.enumerated() {
            guard bone.parent<spec.bones.count,bone.parent<index || bone.parent == -1 else { throw CocoaError(.fileReadCorruptFile) }
            (bone.parent>=0 ? joints[bone.parent] : skeleton).addChildNode(joints[index])
        }
        let inverse=try spec.bones.map { NSValue(scnMatrix4:SCNMatrix4(try matrix($0.inverseBind))) }
        for part in parts {
            guard let file=part["mesh"] as? String,let skin=part["skin"] as? String,let url=Bundle.main.url(forResource:skin,withExtension:nil) else { throw CocoaError(.fileReadCorruptFile) }
            let node=try SpatialAssets.partNode(part,mesh:file)
            guard let geometry=node.geometry,let count=geometry.sources(for:.vertex).first?.vectorCount else { throw CocoaError(.fileReadCorruptFile) }
            let data=try Data(contentsOf:url)
            guard data.count==count*20 else { throw CocoaError(.fileReadCorruptFile) }
            let indices=SCNGeometrySource(data:data,semantic:.boneIndices,vectorCount:count,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:1,dataOffset:0,dataStride:20)
            let weights=SCNGeometrySource(data:data,semantic:.boneWeights,vectorCount:count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:4,dataStride:20)
            let skinner=SCNSkinner(baseGeometry:geometry,bones:joints,boneInverseBindTransforms:inverse,boneWeights:weights,boneIndices:indices)
            skinner.skeleton=skeleton;node.skinner=skinner;root.addChildNode(node)
        }
        play(root,clip:id == "animated_robot" ? "Idle" : "Survey")
        return root
    }

    static func character(in node: SCNNode) -> (SCNNode,String)? {
        for id in identifiers {
            if node.name == "rig:"+id { return (node,id) }
            if let character=node.childNode(withName:"rig:"+id,recursively:true) { return (character,id) }
        }
        return nil
    }

    @discardableResult static func play(_ node: SCNNode,clip name: String) -> Bool {
        guard let (root,id)=character(in:node),let spec=specs[id],let clip=spec.animations.first(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}) else { return false }
        let looping=["Idle","Walking","Running","Dance","Survey","Walk","Run"].contains(clip.name)
        root.removeAction(forKey:"rig-return")
        for index in spec.bones.indices {
            guard let joint=root.childNode(withName:"rig-joint-\(index)",recursively:true) else { return false }
            let animation=CAKeyframeAnimation(keyPath:"transform")
            animation.values=clip.frames.compactMap { frame in try? NSValue(scnMatrix4:SCNMatrix4(matrix(frame[index]))) }
            animation.keyTimes=clip.frames.indices.map { NSNumber(value:Double($0)/Double(clip.frames.count-1)) }
            animation.duration=clip.duration;animation.calculationMode = .linear
            animation.repeatCount=looping ? .infinity : 0;animation.isRemovedOnCompletion=false;animation.fillMode = .forwards
            animation.fadeInDuration=0.12;animation.fadeOutDuration=0.12
            joint.addAnimation(animation,forKey:"rig-motion")
        }
        if !looping {
            root.runAction(.sequence([.wait(duration:clip.duration),.run { [weak root] _ in
                Task { @MainActor in if let root { play(root,clip:id == "animated_robot" ? "Idle" : "Survey") } }
            }]),forKey:"rig-return")
        }
        return true
    }
    static func clear() { specs.removeAll() }
    #if DEBUG
    static func previewPose(_ node: SCNNode,clip: String,fraction: Double) throws {
        guard let (root,id)=character(in:node),let spec=specs[id],let animation=spec.animations.first(where:{$0.name==clip}) else { throw CocoaError(.fileReadCorruptFile) }
        root.removeAllActions()
        let frame=animation.frames[Int(Double(animation.frames.count-1)*min(1,max(0,fraction)))]
        for index in spec.bones.indices {
            let joint=root.childNode(withName:"rig-joint-\(index)",recursively:true)
            joint?.removeAllAnimations();joint?.simdTransform=try matrix(frame[index])
        }
    }
    #endif
}
