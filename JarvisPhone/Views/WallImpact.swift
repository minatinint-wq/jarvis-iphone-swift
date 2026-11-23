import SceneKit
import ARKit

/// A visual effect clipped to an approved measured wall, never a real fracture model.
@MainActor enum WallImpact {
    static func make(center: SIMD2<Float>,outline: [SIMD2<Float>],holes: [WallOpening],height: Float) -> SCNNode {
        let root=SCNNode();root.name="virtual-wall-impact"
        var vertices:[SCNVector3]=[],indices:[Int32]=[]
        for ray in 0..<13 {
            let angle=Float(ray)*2*Float.pi/13
            var previous=center
            for step in 1...9 {
                let length=Float(step)*0.028
                let wobble=sin(Float(ray*17+step*13))*0.013
                let p=center+SIMD2(cos(angle)*length-sin(angle)*wobble,sin(angle)*length+cos(angle)*wobble)
                let direction=p-previous
                let normal=SIMD2(-direction.y,direction.x)/max(0.0001,simd_length(direction))*0.0012
                let quad=[previous+normal,previous-normal,p-normal,p+normal]
                // Small segments are only admitted when their entire quad is on the
                // measured surface and does not intersect a door/window exclusion.
                let safe=quad.allSatisfy { vertex in MeasuredWall.contains(vertex,polygon:outline) && !holes.contains(where:{$0.contains(vertex)}) }
                if safe {
                    let triangles=MeasuredWall.cut([[quad[0],quad[1],quad[2]],[quad[0],quad[2],quad[3]]],openings:holes)
                    for triangle in triangles {
                        for v in triangle { indices.append(Int32(vertices.count));vertices.append(SCNVector3(v.x,height,v.y)) }
                    }
                }
                previous=p
            }
        }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let material=SCNMaterial();material.diffuse.contents=UIColor(white:0.025,alpha:1);material.lightingModel = .constant
        material.isDoubleSided=true;material.writesToDepthBuffer=false;geometry.materials=[material]
        root.addChildNode(SCNNode(geometry:geometry));return root
    }
}

extension WallARController {
    func requestWallAttack() {
        guard tracking,approved,let painted,let position=spatial.selectedCharacterPosition,
              spatial.selectedCharacterID == "animated_robot",let frame=view.session.currentFrame else {
            status="Selecione o robô, marque a parede e confirme o recorte antes do impacto virtual.";return
        }
        let point=CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        guard let query=view.raycastQuery(from:point,allowing:.existingPlaneGeometry,alignment:.vertical),
              let hit=view.session.raycast(query).first else { status="Aponte a mira para a parede marcada.";return }
        let local=simd_inverse(painted.simdWorldTransform)*hit.worldTransform.columns.3
        let p=SIMD2(local.x,local.z)
        guard abs(local.y)<0.10,MeasuredWall.contains(p,polygon:outline),
              !(openings+automaticOpenings).contains(where:{$0.contains(p)}),
              abs(hit.worldTransform.columns.3.y-position.y-1.05)<0.45,
              case .normal=frame.camera.trackingState else { status="Mire na parede livre, aproximadamente na altura da mão do robô.";return }
        spatial.walk(to:SIMD3(hit.worldTransform.columns.3.x,position.y,hit.worldTransform.columns.3.z),impact:SIMD3(hit.worldTransform.columns.3.x,hit.worldTransform.columns.3.y,hit.worldTransform.columns.3.z))
    }
    func showWallImpact(_ point: SIMD3<Float>) {
        guard tracking,approved,let painted,!painted.isHidden else { return }
        let local=simd_inverse(painted.simdWorldTransform)*SIMD4(point,1),p=SIMD2(local.x,local.z)
        guard abs(local.y)<0.10,MeasuredWall.contains(p,polygon:outline),!(openings+automaticOpenings).contains(where:{$0.contains(p)}) else { return }
        let old=painted.childNodes.filter { $0.name == "virtual-wall-impact" }
        if old.count>=4 { old.first?.removeFromParentNode() }
        let height=painted.childNodes.first?.position.y ?? 0.025
        painted.addChildNode(WallImpact.make(center:p,outline:outline,holes:openings+automaticOpenings,height:height+(height<0 ? -0.002 : 0.002)))
        status="Rachadura virtual alinhada ao recorte da parede."
    }
    func repairWall() { painted?.childNodes.filter { $0.name == "virtual-wall-impact" }.forEach { $0.removeFromParentNode() } }
}
