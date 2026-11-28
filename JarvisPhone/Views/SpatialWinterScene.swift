import ARKit
import SceneKit
import UIKit

/// A full-scale winter terrace. The foreground is metric geometry, not room paint.
@MainActor final class SpatialWinterScene {
    private(set) var root:SCNNode?
    var active:Bool { root != nil }
    private var savedLight:Any?
    private var savedIntensity:CGFloat=1
    func open(scene:SCNScene,camera:simd_float4x4,floor:Float) {
        guard root == nil else { return }
        savedLight=scene.lightingEnvironment.contents;savedIntensity=scene.lightingEnvironment.intensity
        let origin=SIMD3(camera.columns.3.x,floor,camera.columns.3.z)
        let node=Self.make();node.simdPosition=origin
        let back=SIMD3(camera.columns.2.x,0,camera.columns.2.z)
        if simd_length(back)>0.1 { node.eulerAngles.y=atan2(back.x,back.z) }
        root=node;scene.rootNode.addChildNode(node)
        scene.lightingEnvironment.contents=Bundle.main.url(forResource:"Winter_light",withExtension:"hdr")
        scene.lightingEnvironment.intensity=0.38
    }
    func close(scene:SCNScene) {
        guard root != nil else { return };root?.removeFromParentNode();root=nil
        scene.lightingEnvironment.contents=savedLight;scene.lightingEnvironment.intensity=savedIntensity;savedLight=nil
    }
    func setTracking(_ ready:Bool) { root?.isHidden = !ready }
    static func make()->SCNNode {
        let root=SCNNode();root.name="Winter-terrace"
        func material(_ prefix:String,tile:Float)->SCNMaterial {
            let m=SCNMaterial();m.lightingModel = .physicallyBased;m.isDoubleSided=true
            for (p,name) in [(m.diffuse,"diff"),(m.normal,"normal"),(m.roughness,"rough")] {
                p.contents=UIImage(named:prefix+"_"+name+".jpg");p.wrapS = .repeat;p.wrapT = .repeat;p.mipFilter = .linear;p.maxAnisotropy=8
                p.contentsTransform=SCNMatrix4MakeScale(tile,tile,1)
            }
            m.normal.intensity=0.55;return m
        }
        let snow=material("Winter_snow",tile:1),stone=material("Winter_stone",tile:3)
        let wood=WallMaterials.make(.wood);wood.roughness.contents=0.85
        let iron=SCNMaterial();iron.lightingModel = .physicallyBased;iron.diffuse.contents=UIColor(white:0.10,alpha:1);iron.metalness.contents=0.6;iron.roughness.contents=0.65
        func box(_ name:String,_ size:SIMD3<Float>,_ p:SIMD3<Float>,_ m:SCNMaterial,bevel:CGFloat=0.025)->SCNNode {
            let g=SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:min(bevel,CGFloat(min(size.x,size.y,size.z))/3));g.chamferSegmentCount=2;g.materials=[m]
            let node=SCNNode(geometry:g);node.name=name;node.simdPosition=p;root.addChildNode(node);return node
        }
        // Smooth low-amplitude drifts outside a clear central terrace.
        var vertices:[SCNVector3]=[],normals:[SCNVector3]=[],uv:[CGPoint]=[],indices:[UInt32]=[]
        let count=65
        func height(_ x:Float,_ z:Float)->Float {
            let edge=max(0,min(1,(max(abs(x),abs(z))-3.1)/4))
            return -0.10+edge*(0.22+0.16*sin(x*0.46)*cos(z*0.38))
        }
        for y in 0..<count { for x in 0..<count {
            let a=Float(x)*0.75-24,b=Float(y)*0.75-24
            vertices.append(SCNVector3(a,height(a,b),b))
            let n=simd_normalize(SIMD3(height(a-0.1,b)-height(a+0.1,b),0.2,height(a,b-0.1)-height(a,b+0.1)))
            normals.append(SCNVector3(n));uv.append(CGPoint(x:CGFloat(a/2),y:CGFloat(b/2)))
        }}
        for y in 0..<(count-1) { for x in 0..<(count-1) { let a=UInt32(y*count+x),b=a+1,c=a+UInt32(count),d=c+1;indices += [a,c,b,b,c,d] } }
        let terrain=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        terrain.materials=[snow];let terrainNode=SCNNode(geometry:terrain);terrainNode.name="Winter-snow-drifts";root.addChildNode(terrainNode)
        _=box("Winter-stone-terrace",SIMD3(6.2,0.16,5.6),SIMD3(0,-0.08,-0.6),stone)
        _=box("Winter-lower-step",SIMD3(6.6,0.12,0.5),SIMD3(0,-0.12,2.40),stone)
        for x:Float in [-3.12,3.12] { _=box("Winter-snow-border",SIMD3(0.18,0.10,5.9),SIMD3(x,0.005,-0.6),snow,bevel:0.035) }
        // Actual benches and sheltered stone lanterns give nearby parallax.
        for x:Float in [-2.4,2.4] {
            for z:Float in [-1.8,-0.4] {
                _=box("Winter-bench-leg",SIMD3(0.12,0.48,0.12),SIMD3(x,0.24,z),iron)
            }
            _=box("Winter-bench-seat",SIMD3(0.48,0.10,1.9),SIMD3(x,0.5,-1.1),wood)
            _=box("Winter-bench-back",SIMD3(0.09,0.52,1.9),SIMD3(x+(x<0 ? -0.23 : 0.23),0.80,-1.1),wood)
            _=box("Winter-bench-snow",SIMD3(0.47,0.035,1.87),SIMD3(x,0.568,-1.1),snow)
        }
        for x:Float in [-2.5,2.5] {
            let stoneCopy=stone.copy() as! SCNMaterial
            _=box("Winter-lantern-base",SIMD3(0.65,0.18,0.65),SIMD3(x,0.09,-3.05),stoneCopy)
            _=box("Winter-lantern-pillar",SIMD3(0.22,0.75,0.22),SIMD3(x,0.60,-3.05),stoneCopy)
            _=box("Winter-lantern-roof",SIMD3(0.7,0.12,0.7),SIMD3(x,1.3,-3.05),snow)
            let warm=SCNMaterial();warm.lightingModel = .constant;warm.diffuse.contents=UIColor(red:1,green:0.72,blue:0.33,alpha:1)
            _=box("Winter-lantern-glass",SIMD3(0.32,0.28,0.32),SIMD3(x,1.08,-3.05),warm)
            let light=SCNNode();light.light=SCNLight();light.light?.type = .omni;light.light?.color=UIColor.orange;light.light?.intensity=85;light.light?.attenuationEndDistance=2.2;light.simdPosition=SIMD3(x,1.1,-3.05);root.addChildNode(light)
        }
        let sky=SCNNode(geometry:SCNSphere(radius:40));sky.name="Winter-sky";sky.position=SCNVector3(0,2,0);sky.renderingOrder = -500
        let panorama=SCNMaterial();panorama.lightingModel = .constant;panorama.diffuse.contents=UIImage(named:"Winter_panorama.jpg");panorama.multiply.contents=UIColor(red:0.30,green:0.40,blue:0.62,alpha:1);panorama.isDoubleSided=true;panorama.writesToDepthBuffer=false
        sky.geometry?.materials=[panorama];root.addChildNode(sky)
        let moon=SCNNode(geometry:SCNSphere(radius:0.8));moon.name="Winter-moon";moon.position=SCNVector3(-13,17,-24);moon.geometry?.firstMaterial?.lightingModel = .constant;moon.geometry?.firstMaterial?.diffuse.contents=UIColor(red:0.85,green:0.91,blue:1,alpha:1);root.addChildNode(moon)
        let sun=SCNNode();sun.name="Winter-cool-light";sun.light=SCNLight();sun.light?.type = .directional;sun.light?.color=UIColor(red:0.72,green:0.83,blue:1,alpha:1);sun.light?.intensity=420;sun.eulerAngles=SCNVector3(-0.65,-0.55,0);root.addChildNode(sun)
        return root
    }
}
