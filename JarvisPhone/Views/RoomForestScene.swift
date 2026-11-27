import ARKit
import SceneKit
import SwiftUI

/// Reuses the captured triangles; furniture is never replaced by guessed boxes.
@MainActor enum RoomForestScene {
    static func points(_ geometry:SCNGeometry)->[SIMD3<Float>] {
        guard let s=geometry.sources(for:.vertex).first else { return [] }
        return s.data.withUnsafeBytes { b in (0..<s.vectorCount).map { i in
            let o=s.dataOffset+i*s.dataStride
            return SIMD3(b.loadUnaligned(fromByteOffset:o,as:Float.self),b.loadUnaligned(fromByteOffset:o+4,as:Float.self),b.loadUnaligned(fromByteOffset:o+8,as:Float.self))
        }}
    }
    static func indices(_ geometry:SCNGeometry)->[UInt32] {
        guard let e=geometry.elements.first,e.bytesPerIndex==4 else { return [] }
        return e.data.withUnsafeBytes { b in (0..<(e.primitiveCount*3)).map { b.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self) } }
    }
    static func capture(base:SCNGeometry,manifest:ScannedRoomManifest,assignments:Data)->RoomForestRegistration.Capture {
        let vertices=points(base),ids=indices(base)
        let labels=assignments.withUnsafeBytes{b in (0..<(assignments.count/4)).map{Int(b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self))}}
        var samples:[RoomForestRegistration.Point]=[]
        for face in stride(from:0,to:ids.count/3,by:max(1,ids.count/3/9000)) {
            let a=vertices[Int(ids[face*3])],b=vertices[Int(ids[face*3+1])],c=vertices[Int(ids[face*3+2])],n=simd_cross(b-a,c-a)
            guard simd_length(n)>0.00001 else { continue }
            let kind=manifest.planes.first{$0.id==labels[face]}?.kind
            samples.append(.init(p:(a+b+c)/3,n:simd_normalize(n),kind:kind=="wall" ? 1 : kind=="floor" ? 2 : 0))
        }
        var walls:[RoomForestRegistration.Wall]=[]
        for plane in manifest.planes where plane.kind=="wall" && plane.normal.count==3 {
            let normal=simd_normalize(SIMD3(plane.normal[0],0,plane.normal[2])),u=simd_cross(SIMD3<Float>(0,1,0),normal)
            let rows=labels.indices.filter{labels[$0]==plane.id}
            var low=Float.infinity,high = -Float.infinity,bottom=Float.infinity,top = -Float.infinity
            for face in rows { for k in 0..<3 {
                let p=vertices[Int(ids[face*3+k])],t=simd_dot(p,u)
                low=min(low,t);high=max(high,t);bottom=min(bottom,p.y);top=max(top,p.y)
            }}
            guard high-low>0.6,top-bottom>0.8,plane.center.count==3 else { continue }
            walls.append(.init(center:SIMD3(plane.center[0],plane.center[1],plane.center[2]),normal:normal,low:low,high:high,bottom:bottom,top:top))
        }
        return .init(floor:manifest.floorY,walls:walls,points:samples)
    }
    static func live(meshes:[ARMeshAnchor],planes:[ARPlaneAnchor])->RoomForestRegistration.Capture? {
        var points:[RoomForestRegistration.Point]=[],floors:[Float]=[]
        for anchor in meshes {
            let g=anchor.geometry;guard let classes=g.classification,g.faces.indexCountPerPrimitive==3 else { continue }
            for face in stride(from:0,to:g.faces.count,by:max(1,g.faces.count/500)) {
                let kind=Int(classes.buffer.contents().advanced(by:classes.offset+face*classes.stride).load(as:UInt8.self))
                var v:[SIMD3<Float>]=[]
                for k in 0..<3 {
                    let ptr=g.faces.buffer.contents().advanced(by:(face*3+k)*g.faces.bytesPerIndex)
                    let i=g.faces.bytesPerIndex==2 ? Int(ptr.load(as:UInt16.self)) : Int(ptr.load(as:UInt32.self))
                    guard i<g.vertices.count else { continue }
                    let b=g.vertices.buffer.contents().advanced(by:g.vertices.offset+i*g.vertices.stride)
                    let p=anchor.transform*SIMD4(b.load(as:Float.self),b.advanced(by:4).load(as:Float.self),b.advanced(by:8).load(as:Float.self),1)
                    v.append(SIMD3(p.x,p.y,p.z))
                }
                guard v.count==3 else { continue };let n=simd_cross(v[1]-v[0],v[2]-v[0]),p=(v[0]+v[1]+v[2])/3
                guard simd_length(n)>0.00001 else { continue }
                let type=kind==ARMeshClassification.wall.rawValue ? 1 : kind==ARMeshClassification.floor.rawValue ? 2 : 0
                if type==2 { floors.append(p.y) }
                if kind != ARMeshClassification.ceiling.rawValue { points.append(.init(p:p,n:simd_normalize(n),kind:type)) }
            }
        }
        let knownFloor=planes.filter{$0.classification == .floor}.map{($0.transform*SIMD4($0.center,1)).y}
        floors += knownFloor;floors.sort();guard !floors.isEmpty else { return nil }
        var walls:[RoomForestRegistration.Wall]=[]
        for p in planes.sorted(by:{$0.extent.x*$0.extent.z > $1.extent.x*$1.extent.z}) where p.alignment == .vertical && (p.classification == .wall || p.classification == .none) {
            let c=p.transform*SIMD4(p.center,1),n=SIMD3(p.transform.columns.1.x,0,p.transform.columns.1.z)
            guard simd_length(n)>0.8,p.extent.x*p.extent.z>0.4 else { continue }
            walls.append(.init(center:SIMD3(c.x,c.y,c.z),normal:simd_normalize(n),low:0,high:0,bottom:c.y-p.extent.z/2,top:c.y+p.extent.z/2))
        }
        return .init(floor:floors[floors.count/2],walls:walls,points:points)
    }
    static func cut(base:SCNGeometry,assignments:Data,opening:RoomDoorwayOpening)->(SCNGeometry,Data) {
        var vertices=points(base);let old=vertices,ids=indices(base),inverse=simd_inverse(opening.pose)
        func attribute(_ semantic:SCNGeometrySource.Semantic,_ count:Int)->[[Float]] {
            guard let s=base.sources(for:semantic).first else { return Array(repeating:Array(repeating:0,count:count),count:old.count) }
            return s.data.withUnsafeBytes { b in (0..<s.vectorCount).map { i in (0..<count).map { k in b.loadUnaligned(fromByteOffset:s.dataOffset+i*s.dataStride+k*4,as:Float.self) } } }
        }
        var normals=attribute(.normal,3).map{SIMD3($0[0],$0[1],$0[2])},uv=attribute(.texcoord,2).map{SIMD2($0[0],$0[1])}
        let originalNormals=normals,originalUV=uv
        let labels=assignments.withUnsafeBytes{b in (0..<(assignments.count/4)).map{b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self)}}
        var out:[UInt32]=[],outLabels:[Int32]=[]
        let hole=WallOpening(SIMD2(-opening.width/2,-opening.height/2),SIMD2(opening.width/2,opening.height/2),margin:0)
        for f in labels.indices {
            let index=(0..<3).map{Int(ids[f*3+$0])},p=index.map{inverse*SIMD4(old[$0],1)}
            if p.allSatisfy({abs($0.z)<0.09}) && p.map(\.x).max()! > -opening.width/2 && p.map(\.x).min()! < opening.width/2 && p.map(\.y).max()! > -opening.height/2 && p.map(\.y).min()! < opening.height/2 {
                let xy=p.map{SIMD2($0.x,$0.y)},a=xy[0],b=xy[1],c=xy[2]
                let det=(b.y-c.y)*(a.x-c.x)+(c.x-b.x)*(a.y-c.y)
                guard abs(det)>0.000001 else { continue }
                for triangle in MeasuredWall.triangles(xy,excluding:[hole]) {
                    for q in triangle {
                        let wa=((b.y-c.y)*(q.x-c.x)+(c.x-b.x)*(q.y-c.y))/det
                        let wb=((c.y-a.y)*(q.x-c.x)+(a.x-c.x)*(q.y-c.y))/det,wc=1-wa-wb
                        out.append(UInt32(vertices.count));vertices.append(old[index[0]]*wa+old[index[1]]*wb+old[index[2]]*wc)
                        let n=originalNormals[index[0]]*wa+originalNormals[index[1]]*wb+originalNormals[index[2]]*wc
                        normals.append(simd_length(n)>0.01 ? simd_normalize(n) : SIMD3(0,1,0));uv.append(originalUV[index[0]]*wa+originalUV[index[1]]*wb+originalUV[index[2]]*wc)
                    }
                    outLabels.append(labels[f])
                }
            } else { out.append(contentsOf:ids[(f*3)..<(f*3+3)]);outLabels.append(labels[f]) }
        }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices.map{SCNVector3($0)}),SCNGeometrySource(normals:normals.map{SCNVector3($0)}),SCNGeometrySource(textureCoordinates:uv.map{CGPoint(x:CGFloat($0.x),y:CGFloat($0.y))})],elements:[SCNGeometryElement(data:out.withUnsafeBytes{Data($0)},primitiveType:.triangles,primitiveCount:out.count/3,bytesPerIndex:4)])
        geometry.materials=base.materials
        return (geometry,outLabels.withUnsafeBytes{Data($0)})
    }
    static func floorSpots(base:SCNGeometry,manifest m:ScannedRoomManifest,assignments:Data,radius:Float=0.30)->[SIMD3<Float>] {
        let v=points(base),ids=indices(base),labels=assignments.withUnsafeBytes{b in (0..<(assignments.count/4)).map{Int(b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self))}}
        var occupied=Set<String>()
        func key(_ p:SIMD3<Float>)->String { "\(Int(floor(p.x/0.16))),\(Int(floor(p.z/0.16)))" }
        for f in stride(from:0,to:ids.count/3,by:2) {
            let q=(v[Int(ids[f*3])]+v[Int(ids[f*3+1])]+v[Int(ids[f*3+2])])/3
            if q.y>m.floorY+0.22 && q.y<m.floorY+2 { occupied.insert(key(q)) }
        }
        var result:[SIMD3<Float>]=[]
        let floors=Set(m.planes.filter{$0.kind=="floor"}.map(\.id))
        for f in stride(from:0,to:ids.count/3,by:23) where result.count<100 {
            guard floors.contains(labels[f]) else { continue }
            let q=(v[Int(ids[f*3])]+v[Int(ids[f*3+1])]+v[Int(ids[f*3+2])])/3
            guard result.allSatisfy({simd_distance($0,q)>0.38}) else { continue }
            var free=true
            for dx in stride(from:-radius,through:radius,by:0.15) { for dz in stride(from:-radius,through:radius,by:0.15) { if occupied.contains(key(q+SIMD3(dx,0,dz))) { free=false } } }
            if free { result.append(q) }
        }
        return result
    }
    static func make(base:SCNGeometry,manifest m:ScannedRoomManifest,assignments:Data,opening:RoomDoorwayOpening?=nil)->SCNNode {
        if let opening { let (geometry,labels)=cut(base:base,assignments:assignments,opening:opening);return make(base:geometry,manifest:m,assignments:labels) }
        let root=SCNNode();root.name="RoomForest-captured-geometry"
        let v=points(base),ids=indices(base),labels=assignments.withUnsafeBytes{b in (0..<(assignments.count/4)).map{Int(b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self))}}
        let floorCenter=m.planes.first{$0.kind=="floor"}?.center ?? [0,m.floorY,0]
        let center=SIMD3(floorCenter[0],m.floorY,floorCenter[2])
        var batches:[Int:[UInt32]]=[:]
        for f in labels.indices { batches[labels[f],default:[]].append(contentsOf:ids[(f*3)..<(f*3+3)]) }
        for (id,indices) in batches {
            let plane=m.planes.first{$0.id==id},kind=plane?.kind ?? "furniture"
            var sources=base.sources
            if let plane,plane.normal.count==3 {
                let n=SIMD3(plane.normal[0],plane.normal[1],plane.normal[2])
                let u=abs(n.y)>0.7 ? SIMD3<Float>(1,0,0) : simd_normalize(simd_cross(SIMD3<Float>(0,1,0),n))
                let uv=v.map{SIMD2(simd_dot($0,u),abs(n.y)>0.7 ? $0.z : $0.y)}
                sources=base.sources.filter{$0.semantic != .texcoord}+[SCNGeometrySource(data:uv.withUnsafeBytes{Data($0)},semantic:.texcoord,vectorCount:v.count,usesFloatComponents:true,componentsPerVector:2,bytesPerComponent:4,dataOffset:0,dataStride:8)]
            }
            let g=SCNGeometry(sources:sources,elements:[SCNGeometryElement(data:indices.withUnsafeBytes{Data($0)},primitiveType:.triangles,primitiveCount:indices.count/3,bytesPerIndex:4)])
            let material:SCNMaterial
            if kind=="furniture" { material=base.firstMaterial?.copy() as? SCNMaterial ?? SCNMaterial();material.multiply.contents=UIColor(red:0.82,green:0.94,blue:0.80,alpha:1) }
            else {
                material=SCNMaterial();material.lightingModel = .physicallyBased;material.isDoubleSided=true
                let floor=kind=="floor",prefix=floor ? "Portal_forest_floor_" : "RoomForest_moss_",suffix=floor ? "_2k" : ""
                for (property,key) in [(material.diffuse,"diff"),(material.normal,"nor_gl"),(material.roughness,"rough")] {
                    property.contents=UIImage(named:prefix+key+suffix+".jpg");property.wrapS = .repeat;property.wrapT = .repeat
                    property.contentsTransform=SCNMatrix4MakeScale(floor ? 0.7 : 0.9,floor ? 0.7 : 0.9,1);property.mipFilter = .linear;property.maxAnisotropy=4
                }
                material.normal.intensity=0.45
                if kind=="ceiling" { material.multiply.contents=UIColor(red:0.43,green:0.60,blue:0.37,alpha:1) }
            }
            g.materials=[material];let node=SCNNode(geometry:g);node.name="RoomForest-plane-\(id)";root.addChildNode(node)
        }
        // A conservative occupied-height grid keeps vegetation off the captured furniture.
        var occupied=Set<String>()
        func key(_ p:SIMD3<Float>)->String { "\(Int(floor(p.x/0.18))),\(Int(floor(p.z/0.18)))" }
        for f in stride(from:0,to:ids.count/3,by:2) {
            let p=(v[Int(ids[f*3])]+v[Int(ids[f*3+1])]+v[Int(ids[f*3+2])])/3
            if p.y>m.floorY+0.25 && p.y<m.floorY+2 { occupied.insert(key(p)) }
        }
        func add(_ id:String,at p:SIMD3<Float>,size:Float,yaw:Float) {
            guard let plant=try? SpatialAssets.load(id) else { return }
            plant.simdPosition=p;plant.simdScale=SIMD3(repeating:size);plant.eulerAngles.y=yaw
            if id=="fern" { plant.runAction(.repeatForever(.sequence([.rotateBy(x:0,y:0,z:0.018,duration:3.2),.rotateBy(x:0,y:0,z:-0.018,duration:3.2)])),forKey:"breeze") }
            plant.name="RoomForest-vegetation";root.addChildNode(plant)
        }
        var planted:[SIMD3<Float>]=[]
        for f in stride(from:0,to:ids.count/3,by:37) where planted.count<10 {
            guard m.planes.first(where:{$0.id==labels[f]})?.kind=="floor" else { continue }
            let p=(v[Int(ids[f*3])]+v[Int(ids[f*3+1])]+v[Int(ids[f*3+2])])/3
            guard planted.allSatisfy({simd_distance($0,p)>0.7}) else { continue }
            var free=true
            for dx in [-0.25,Float(0),0.25] { for dz in [-0.25,Float(0),0.25] { if occupied.contains(key(p+SIMD3(dx,0,dz))) { free=false } } }
            guard free else { continue };planted.append(p)
            add(planted.count<=1 && ids.count/3<280000 ? "treestump" : "fern",at:p,size:planted.count<=1 && ids.count/3<280000 ? 0.55 : 0.42,yaw:Float(f)*0.7)
        }
        for plane in m.planes.filter({$0.kind=="wall" && $0.center.count==3 && $0.normal.count==3}).prefix(12) {
            let p=SIMD3(plane.center[0],plane.center[1],plane.center[2]),n=simd_normalize(SIMD3(plane.normal[0],0,plane.normal[2]))
            let inward=simd_dot(center-p,n)>0 ? n : -n
            guard let ivy=try? SpatialAssets.load("fern") else { continue }
            ivy.simdPosition=p+inward*0.04;ivy.simdScale=SIMD3(repeating:0.38);ivy.simdOrientation=simd_quatf(from:SIMD3(0,1,0),to:inward)
            ivy.name="RoomForest-wall-growth";root.addChildNode(ivy)
        }
        let sky=SCNNode(geometry:SCNSphere(radius:12));sky.name="RoomForest-sky";sky.simdPosition=center+SIMD3(0,1.3,0);sky.renderingOrder = -100
        let panorama=SCNMaterial();panorama.lightingModel = .constant;panorama.isDoubleSided=true;panorama.writesToDepthBuffer=false
        panorama.diffuse.contents=UIImage(named:"RoomForest_sky.jpg");sky.geometry?.materials=[panorama];root.addChildNode(sky)
        let sun=SCNNode();sun.light=SCNLight();sun.light?.type = .directional;sun.light?.color=UIColor(red:1,green:0.91,blue:0.72,alpha:1);sun.light?.intensity=450;sun.eulerAngles=SCNVector3(-0.7,-0.5,0);root.addChildNode(sun)
        return root
    }
}
