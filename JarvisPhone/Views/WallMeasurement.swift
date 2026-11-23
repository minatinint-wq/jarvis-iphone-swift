import SwiftUI
import ARKit
import SceneKit

extension WallARController {
    func beginOutline() {
        spatial.active=false
        if !selected { _=select(); return }
        approved=false; painted?.childNodes.first?.geometry=nil
        draft=[]; outline=[]; openings=[]; pointsCount=0; openingsCount=0
        measureMode = .outline; invalidatePaint(); redrawMarkers()
        status="Marque pelo menos 3 cantos em ordem, como no Medidas."
    }
    func beginOpening() {
        guard selected else { status="Marque a parede primeiro."; return }
        if measureMode == .outline {
            guard MeasuredWall.valid(draft) else { status="Marque pelo menos 3 cantos, sem cruzar as linhas."; return }
            outline=draft
        }
        guard MeasuredWall.valid(outline), openings.count<12 else { status="Marque a parede primeiro. Limite: 12 exclusões."; return }
        approved=false; invalidatePaint()
        draft=[]; measureMode = .opening; pointsCount=0; redrawMarkers()
        status="Marque dois cantos opostos da porta, janela ou armário. Essa área ficará transparente."
    }
    private func wallPoint(_ screen: CGPoint) -> SIMD2<Float>? {
        guard tracking, let anchor=worldAnchor,
              let query=view.raycastQuery(from:screen,allowing:.estimatedPlane,alignment:.any) else { return nil }
        let inverse=simd_inverse(anchor.transform)
        let origin=inverse * SIMD4<Float>(query.origin,1)
        let direction=inverse * SIMD4<Float>(query.direction,0)
        guard abs(direction.y)>0.10 else { return nil }
        let distance = -origin.y/direction.y
        guard distance>0.15, distance<4.5 else { return nil }
        let point=origin+direction*distance
        return SIMD2<Float>(point.x,point.z)
    }
    func addPoint(at point: CGPoint? = nil) {
        guard measureMode != .none else { status="Escolha Marcar parede ou Excluir área."; return }
        guard let p=wallPoint(point ?? CGPoint(x:view.bounds.midX,y:view.bounds.midY)) else {
            status="Aponte de frente para a parede e aguarde a posição estabilizar."; return
        }
        if let last=draft.last {
            let length=simd_distance(last,p); guard length>0.025 else { return }
            measurement=String(format:"Último segmento: %.2f m",length)
        }
        guard draft.count<12 else { status="Limite de 12 pontos. Conclua o contorno."; return }
        draft.append(p); pointsCount=draft.count
        if measureMode == .opening && draft.count==2 {
            let hole=WallOpening(draft[0],draft[1])
            guard hole.high.x-hole.low.x>0.06, hole.high.y-hole.low.y>0.06 else {
                draft.removeLast(); pointsCount=1; status="Marque o canto oposto na diagonal."; return
            }
            openings.append(hole); openingsCount=openings.count
            draft=[]; pointsCount=0; measureMode = .none
            status="Área excluída. Adicione outra exclusão ou toque em Aplicar."
        } else { status="\(draft.count) ponto(s). Continue pelos cantos em ordem." }
        redrawMarkers(); UIImpactFeedbackGenerator(style:.light).impactOccurred()
    }
    func undoPoint() {
        if !draft.isEmpty { draft.removeLast(); pointsCount=draft.count }
        else if !openings.isEmpty { openings.removeLast(); openingsCount=openings.count; approved=false; invalidatePaint() }
        redrawMarkers()
    }
    func confirm() {
        guard tracking else { status="Espere o rastreamento estabilizar."; return }
        if measureMode == .opening { status="Falta o segundo canto da exclusão."; return }
        if measureMode == .outline { outline=draft }
        guard MeasuredWall.valid(outline) else { status="Contorno incompleto ou cruzado. Desfaça e marque os cantos em ordem."; return }
        measureMode = .none; draft=[]; pointsCount=0; approved=true; comparing=false
        automaticOpenings=detectedOpenings(); invalidatePaint(); redrawMarkers()
        status="Contorno confirmado. Passe a câmera devagar: só aparece pintura onde a profundidade confirma parede."
        feedback(status)
    }
    func invalidatePaint() {
        paintRevision += 1; depthEvidence=WallDepthEvidence()
        painted?.childNodes.first?.geometry=nil
    }
    private func detectedOpenings() -> [WallOpening] {
        guard let anchor=worldAnchor else { return [] }
        let inverse=simd_inverse(anchor.transform)
        return planes.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.compactMap { plane in
            guard plane.classification == .door || plane.classification == .window else { return nil }
            let points=plane.geometry.boundaryVertices.map { inverse * plane.transform * SIMD4<Float>($0.x,$0.y,$0.z,1) }
            guard points.count>=3, points.allSatisfy({ abs($0.y)<0.35 }) else { return nil }
            let local=points.map { SIMD2<Float>($0.x,$0.z) }
            let lo=local.reduce(local[0],{ simd_min($0,$1) }), hi=local.reduce(local[0],{ simd_max($0,$1) })
            return WallOpening(lo,hi,margin:0.04)
        }
    }
    func refreshAutomaticOpenings() {
        let fresh=detectedOpenings()
        let changed=fresh.count != automaticOpenings.count || zip(fresh,automaticOpenings).contains { simd_distance($0.low,$1.low)>0.04 || simd_distance($0.high,$1.high)>0.04 }
        if changed { automaticOpenings=fresh; invalidatePaint() }
    }
    func updateDepth(_ frame: ARFrame) {
        guard !depthPending, let anchor=worldAnchor, let depth=frame.smoothedSceneDepth,
              let confidence=depth.confidenceMap else { return }
        lastDepthUpdate=frame.timestamp; depthPending=true
        let revision=paintRevision, boundary=outline, holes=openings+automaticOpenings
        let transform=simd_inverse(frame.camera.transform)*anchor.transform
        let intrinsics=frame.camera.intrinsics, imageSize=frame.camera.imageResolution
        var evidence=depthEvidence
        meshQueue.async { [weak self] in
            let triangles=WallDepthEvidence.subdivide(MeasuredWall.triangles(boundary,excluding:holes))
            let readings=Self.readDepth(triangles,transform:transform,intrinsics:intrinsics,imageSize:imageSize,depth:depth.depthMap,confidence:confidence)
            let visible=evidence.observe(readings)
            let vertices=visible.flatMap { triangles[$0] }
            let geometry=Self.paintGeometry(vertices)
            let area=visible.reduce(Float(0)) { $0+MeasuredWall.area(triangles[$1]) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.depthPending=false
                guard !self.stopped, self.approved, self.paintRevision==revision else { return }
                self.depthEvidence=evidence
                geometry?.materials=[self.materials[self.finish] ?? WallMaterials.make(self.finish)]
                self.painted?.childNodes.first?.geometry=geometry
                self.measuredArea=area
                self.measurement=String(format:"%.2f m² confirmados · %d exclusões",area,holes.count)
                if visible.isEmpty { self.status="Profundidade ainda insuficiente. Mostre a parede de frente, a menos de 4,5 m." }
            }
        }
    }
    nonisolated static func paintGeometry(_ vertices: [SIMD2<Float>]) -> SCNGeometry? {
        guard !vertices.isEmpty else { return nil }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices.map { SCNVector3($0.x,0,$0.y) }),
            SCNGeometrySource(normals:vertices.map { _ in SCNVector3(0,1,0) }),
            SCNGeometrySource(textureCoordinates:vertices.map { CGPoint(x:CGFloat($0.x),y:CGFloat($0.y)) })],
            elements:[SCNGeometryElement(indices:vertices.indices.map(UInt32.init),primitiveType:.triangles)])
    }
    nonisolated private static func readDepth(_ triangles: [[SIMD2<Float>]], transform: simd_float4x4,
                                             intrinsics: simd_float3x3, imageSize: CGSize,
                                             depth: CVPixelBuffer, confidence: CVPixelBuffer) -> [WallDepthReading] {
        CVPixelBufferLockBaseAddress(depth,.readOnly); CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth,.readOnly); CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        guard let d=CVPixelBufferGetBaseAddress(depth), let c=CVPixelBufferGetBaseAddress(confidence) else { return triangles.map { _ in .unknown } }
        let width=CVPixelBufferGetWidth(depth), height=CVPixelBufferGetHeight(depth)
        let ds=CVPixelBufferGetBytesPerRow(depth), cs=CVPixelBufferGetBytesPerRow(confidence)
        func sample(_ point: SIMD2<Float>) -> WallDepthReading {
            let p=transform*SIMD4<Float>(point.x,0,point.y,1), z = -p.z
            guard z>0 else { return .outside }
            let u=(intrinsics[0][0]*p.x/z+intrinsics[2][0])/Float(imageSize.width)*Float(width)
            let v=(-intrinsics[1][1]*p.y/z+intrinsics[2][1])/Float(imageSize.height)*Float(height)
            guard u>=1, v>=1, u<Float(width-1), v<Float(height-1) else { return .outside }
            let x=Int(u), y=Int(v)
            let observed=d.advanced(by:y*ds+x*4).load(as:Float.self)
            let certainty=c.advanced(by:y*cs+x).load(as:UInt8.self)
            return WallDepthEvidence.classify(expected:z,measured:observed,confidence:certainty)
        }
        return triangles.map { t in
            let center=(t[0]+t[1]+t[2])/3
            let values=([center]+t.map { $0*0.9+center*0.1 }).map(sample)
            if values.contains(where:{ if case .obstacle=$0 { return true }; return false }) { return .obstacle }
            if values.allSatisfy({ if case .wall=$0 { return true }; return false }) { return .wall }
            if values.allSatisfy({ if case .outside=$0 { return true }; return false }) { return .outside }
            return .unknown
        }
    }
    func redrawMarkers() {
        markers.childNodes.forEach { $0.removeFromParentNode() }
        func draw(_ points: [SIMD2<Float>], _ color: UIColor, closed: Bool) {
            guard !points.isEmpty else { return }
            for p in points {
                let dot=SCNNode(geometry:SCNSphere(radius:0.012)); dot.position=SCNVector3(p.x,0,p.y)
                dot.geometry?.firstMaterial?.diffuse.contents=color; dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.geometry?.firstMaterial?.readsFromDepthBuffer=false; markers.addChildNode(dot)
            }
            let count=closed ? points.count : points.count-1
            for i in 0..<max(0,count) {
                let a=points[i], b=points[(i+1)%points.count]; guard simd_distance(a,b)>0.001 else { continue }
                let line=SCNNode(geometry:SCNCylinder(radius:0.003,height:CGFloat(simd_distance(a,b))))
                line.simdPosition=SIMD3<Float>((a.x+b.x)/2,0,(a.y+b.y)/2)
                line.simdOrientation=simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(SIMD3<Float>(b.x-a.x,0,b.y-a.y)))
                line.geometry?.firstMaterial?.diffuse.contents=color; line.geometry?.firstMaterial?.lightingModel = .constant
                line.geometry?.firstMaterial?.readsFromDepthBuffer=false; markers.addChildNode(line)
            }
        }
        if !approved { draw(outline,.cyan,closed:true) }
        draw(draft,measureMode == .opening ? .systemOrange : .cyan,closed:measureMode == .outline && draft.count>2)
        if !approved { for hole in openings+detectedOpenings() { draw(hole.corners,.systemOrange,closed:true) } }
    }
}
