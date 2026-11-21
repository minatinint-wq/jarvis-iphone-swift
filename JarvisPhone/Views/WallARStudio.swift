import SwiftUI
import ARKit
import SceneKit
import AVFoundation

struct WallARRequest: Equatable {
    let id = UUID()
    let command: WallARCommand
}

enum WallMaterials {
    private static var images: [String: UIImage] = [:]
    static func make(_ finish: WallFinish) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        material.metalness.contents = 0.0
        let (r,g,b) = finish.rgb
        material.multiply.contents = UIColor(red:r, green:g, blue:b, alpha:1)
        for (property, channel) in [(material.diffuse,"Color"),(material.normal,"NormalGL"),(material.roughness,"Roughness")] {
            let name = "AR_\(finish.texture)_\(channel)"
            if images[name] == nil, let path = Bundle.main.path(forResource:name, ofType:"jpg") {
                images[name] = UIImage(contentsOfFile:path)
            }
            property.contents = images[name]
            property.wrapS = .repeat; property.wrapT = .repeat
            property.minificationFilter = .linear; property.magnificationFilter = .linear
            property.mipFilter = .linear; property.maxAnisotropy = 8
            property.contentsTransform = SCNMatrix4MakeScale(1 / finish.tileMeters, 1 / finish.tileMeters, 1)
        }
        material.normal.intensity = finish == .wood ? 0.3 : 0.18
        return material
    }
}

/// Owns one live ARSession. Painted geometry has its own world anchor and frozen
/// metric UVs, so plane refinement cannot stretch the texture or move its edges.
@MainActor final class WallARController: NSObject, ObservableObject, ARSessionDelegate {
    @Published var status = "Mostre a parede, o encontro com o teto e os cantos."
    @Published var selected = false
    @Published var finish = WallFinish.white
    @Published var tracking = false
    @Published var comparing = false
    @Published var prepared = false
    @Published var fatal = false
    @Published var metrics = "Preparando câmera"
    @Published var notice = ""
    let view = ARSCNView(frame:.zero, options:[SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    private var planes: [UUID:ARPlaneAnchor] = [:]
    private var painted: SCNNode?
    private var worldAnchor: ARAnchor?
    private var history: [WallFinish] = []
    private var occluders: [UUID:SCNNode] = [:]
    private var meshUpdated: [UUID:TimeInterval] = [:]
    private var materials: [WallFinish:SCNMaterial] = [:]
    private var gate = WallTrackingGate()
    private var foreground = true
    private var started = false
    private var stopped = false
    private var lastMetric: TimeInterval = 0
    private var cameraFrames = 0
    private var stableLight: CGFloat = 350
    private let light = SCNLight()
    private var performance = WallRenderMeter()
    private var lastFeedback: TimeInterval = 0
    var onFeedback: ((String) -> Void)?

    override init() {
        super.init()
        view.scene = SCNScene()
        view.session.delegate = self
        view.session.delegateQueue = .main
        view.delegate = performance
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        light.type = .ambient; light.intensity = stableLight
        let node = SCNNode(); node.light = light
        view.scene.rootNode.addChildNode(node)
        let tap = UITapGestureRecognizer(target:self, action:#selector(tapped(_:)))
        view.addGestureRecognizer(tap)
    }

    func start() async {
        guard !started, !stopped else { return }
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            status = "Este modo precisa de um iPhone com LiDAR. O simulador não reproduz o rastreamento."; fatal = true; return
        }
        let permission = await AVCaptureDevice.requestAccess(for:.video)
        guard !stopped else { return }
        guard permission else { status = "Permita a câmera nos Ajustes para pintar em AR."; fatal = true; return }
        // Decode and upload once, before scanning; no image generation or downloading
        // competes with tracking. Shared PBR textures use metric UVs and mipmaps.
        for f in WallFinish.allCases { materials[f] = WallMaterials.make(f) }
        view.prepare(Array(materials.values)) { [weak self] ready in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.prepared = ready
                self.started = true
                if self.foreground { self.run() }
            }
        }
    }

    private func run() {
        guard foreground, !stopped, !fatal else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal,.vertical]
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        // Prefer moderate camera resolution at 60 Hz rather than 4K capture + AI.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter { $0.framesPerSecond == 60 }
        if let format = formats.min(by: { $0.imageResolution.width < $1.imageResolution.width }) { config.videoFormat = format }
        view.session.run(config)
        view.isPlaying = true
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active && started { run() }
        else if !active {
            view.session.pause(); view.isPlaying = false
            tracking = false; _ = gate.update(normal:false, at:0); setVisible(false)
        }
    }

    func stop() {
        stopped = true
        view.session.pause(); view.isPlaying = false
        view.session.delegate = nil; view.delegate = nil
        onFeedback = nil
        materials.removeAll(); occluders.removeAll(); planes.removeAll()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) { select(at:gesture.location(in:view)) }

    @discardableResult func select(at point: CGPoint? = nil) -> Bool {
        guard prepared, tracking, !fatal else { status = "Aguarde o rastreamento estabilizar antes de selecionar."; return false }
        let position = point ?? CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        guard let query = view.raycastQuery(from:position, allowing:.existingPlaneGeometry, alignment:.vertical),
              let hit = view.session.raycast(query).first,
              let plane = hit.anchor as? ARPlaneAnchor,
              plane.classification != .door, plane.classification != .window,
              plane.extent.x > 0.25, plane.extent.z > 0.25 else {
            status = "Ainda não encontrei uma parede nesse ponto. Mostre também os cantos e tente de novo."; return false
        }
        let edges = boundaries(for:plane)
        let outline = plane.geometry.boundaryVertices.map { SIMD2<Float>($0.x,$0.z) }
        let fitted = WallBoundary.fitted(outline,edges:edges)
        guard WallBoundary.touchesCeiling(fitted,edges:edges) else {
            status = "Mostre o encontro dessa parede com o teto e os cantos; depois selecione de novo. Ainda falta mapear a borda superior."
            return false
        }
        guard let geometry = Self.surface(fitted) else { status = "O contorno ainda está incompleto. Mostre os cantos da parede."; return false }
        clear(silent:true)
        geometry.materials = [materials[finish] ?? WallMaterials.make(finish)]
        let root = SCNNode()
        root.simdTransform = plane.transform
        let surface = SCNNode(geometry:geometry)
        // Lift toward camera, not blindly toward the plane normal.
        if let frame = view.session.currentFrame {
            let localCamera = simd_inverse(plane.transform) * frame.camera.transform.columns.3
            surface.position.y = localCamera.y >= 0 ? 0.008 : -0.008
        }
        root.addChildNode(surface)
        let anchor = ARAnchor(name:"JarvisPaintedWall", transform:plane.transform)
        worldAnchor = anchor; painted = root
        view.scene.rootNode.addChildNode(root)
        view.session.add(anchor:anchor)
        selected = true; comparing = false; history = []
        status = "\(finish.title) fixado. Mova o iPhone para conferir."
        notice = "Encaixe no teto detectado · \(edges.filter { !$0.ceiling }.count) limites adicionais. Confira janelas e quadros."
        return true
    }

    /// Use meters directly, not ARKit's changing normalized texture coordinates.
    static func surface(_ outline: [SIMD2<Float>]) -> SCNGeometry? {
        let indices = WallBoundary.triangles(outline)
        guard !indices.isEmpty else { return nil }
        let vertices = outline.map { SCNVector3($0.x,0,$0.y) }
        let uv = outline.map { CGPoint(x:CGFloat($0.x),y:CGFloat($0.y)) }
        let normals = outline.map { _ in SCNVector3(0,1,0) }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)],
                           elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    }

    private func boundaries(for wall: ARPlaneAnchor) -> [WallEdge] {
        let origin = SIMD3<Float>(wall.transform.columns.3.x,wall.transform.columns.3.y,wall.transform.columns.3.z)
        let axisX = SIMD3<Float>(wall.transform.columns.0.x,wall.transform.columns.0.y,wall.transform.columns.0.z)
        let axisZ = SIMD3<Float>(wall.transform.columns.2.x,wall.transform.columns.2.y,wall.transform.columns.2.z)
        let inverse = simd_inverse(wall.transform)
        let center = SIMD2<Float>(wall.center.x,wall.center.z)
        var edges: [WallEdge] = []
        for other in planes.values where other.identifier != wall.identifier {
            guard other.classification == .ceiling || other.classification == .floor || other.classification == .wall else { continue }
            // Only planes whose measured footprint reaches this wall define a corner.
            let footprint = other.geometry.boundaryVertices.map { inverse * other.transform * SIMD4<Float>($0.x,$0.y,$0.z,1) }
            guard !footprint.isEmpty,
                  (footprint.map { $0.y }.min() ?? 1) <= 0.25,
                  (footprint.map { $0.y }.max() ?? -1) >= -0.25 else { continue }
            let n = SIMD3<Float>(other.transform.columns.1.x,other.transform.columns.1.y,other.transform.columns.1.z)
            let p = SIMD3<Float>(other.transform.columns.3.x,other.transform.columns.3.y,other.transform.columns.3.z)
            var normal = SIMD2<Float>(simd_dot(n,axisX),simd_dot(n,axisZ))
            let length = simd_length(normal)
            guard length > 0.5 else { continue }
            normal /= length
            var offset = simd_dot(n,origin-p)/length
            if simd_dot(normal,center)+offset < 0 { normal = -normal; offset = -offset }
            edges.append(WallEdge(normal:normal,offset:offset,ceiling:other.classification == .ceiling))
        }
        return edges
    }

    func apply(_ command: WallARCommand) {
        switch command {
        case .open: break
        case .select:
            if select() { feedback("Parede selecionada. \(finish.title) aplicado.") }
            else { feedback(status) }
        case .finish(let value):
            let old = finish
            finish = value
            if selected {
                if old != value { history.append(old); if history.count > 20 { history.removeFirst() } }
                painted?.childNodes.first?.geometry?.materials = [materials[value] ?? WallMaterials.make(value)]
                comparing = false; setVisible(tracking)
                status = "\(value.title) aplicado à mesma parede."
                feedback(status)
            } else if select() { feedback("\(value.title) aplicado à parede à sua frente.") }
            else { status = "\(value.title) escolhido. Enquadre a parede e diga “essa parede” ou toque nela."; feedback(status) }
        case .undo:
            guard let previous = history.popLast() else { feedback("Não há outra cor para desfazer nesta parede."); return }
            finish = previous; painted?.childNodes.first?.geometry?.materials = [materials[previous] ?? WallMaterials.make(previous)]
            comparing = false; setVisible(tracking); status = "Voltei para \(previous.title)."; feedback(status)
        case .clear: clear(); feedback("Pintura removida.")
        case .compare: comparing.toggle(); setVisible(tracking && !comparing); status = comparing ? "Parede original." : "Pintura AR." 
        case .close: break
        }
    }

    private func feedback(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastFeedback > 0.8 else { return }
        lastFeedback = now; onFeedback?(text)
    }
    private func clear(silent: Bool = false) {
        if let anchor = worldAnchor { view.session.remove(anchor:anchor) }
        worldAnchor = nil; painted?.removeFromParentNode(); painted = nil
        selected = false; comparing = false; history.removeAll()
        if !silent { status = "Pintura removida. Escolha outra parede." }
    }
    private func setVisible(_ visible: Bool) {
        // No fade, camera tween, flashing reticle or screen-space fallback.
        // Gate has a dwell time, preventing normal/limited oscillation flicker.
        painted?.isHidden = !visible
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard foreground, !stopped else { return }
        let normal: Bool
        switch frame.camera.trackingState { case .normal: normal = true; default: normal = false }
        let good = gate.update(normal:normal, at:frame.timestamp)
        if tracking != good {
            tracking = good; setVisible(good && !comparing)
            status = good ? (selected ? "Parede fixada. Pode mudar o material por voz." : "Toque na parede ou diga “essa parede”.") : "Recuperando posição. Mova devagar e mostre detalhes do ambiente."
        }
        cameraFrames += 1
        if frame.timestamp-lastMetric >= 1 {
            let fps = performance.sample()
            metrics = fps > 0 ? "\(fps) FPS · LiDAR · local" : "LiDAR · renderização local"
            lastMetric = frame.timestamp; cameraFrames = 0
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical {
                fatal = true; setVisible(false); view.session.pause(); view.isPlaying = false
                status = "iPhone quente. AR pausado; feche e deixe o aparelho esfriar."; return
            }
            view.preferredFramesPerSecond = thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
            if thermal == .serious { notice = "iPhone aquecendo: renderização limitada a 30 FPS." }
            if let estimate = frame.lightEstimate {
                let target = CGFloat(min(600,max(120,estimate.ambientIntensity * 0.35)))
                stableLight += (target-stableLight)*0.12; light.intensity = stableLight
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { update(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { update(anchors) }
    private func update(_ anchors: [ARAnchor]) {
        guard !stopped else { return }
        for anchor in anchors {
            if anchor.identifier == worldAnchor?.identifier { painted?.simdTransform = anchor.transform }
            if let plane = anchor as? ARPlaneAnchor { planes[plane.identifier] = plane }
            if let mesh = anchor as? ARMeshAnchor { updateOccluder(mesh) }
        }
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            planes.removeValue(forKey:anchor.identifier)
            occluders.removeValue(forKey:anchor.identifier)?.removeFromParentNode()
            meshUpdated.removeValue(forKey:anchor.identifier)
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        tracking = false; _ = gate.update(normal:false,at:0); setVisible(false)
        status = "AR interrompido. A pintura reaparece após recuperar a posição."
    }
    func sessionInterruptionEnded(_ session: ARSession) { if foreground { run() } }
    func session(_ session: ARSession, didFailWithError error: Error) {
        fatal = true; setVisible(false); status = "AR indisponível: \(error.localizedDescription). Feche e reabra este modo."
    }

    private func updateOccluder(_ anchor: ARMeshAnchor) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now-(meshUpdated[anchor.identifier] ?? 0) > 0.5 else { return }
        guard occluders[anchor.identifier] != nil || occluders.count < 48 else { return }
        meshUpdated[anchor.identifier] = now
        let mesh = anchor.geometry
        let vertices = SCNGeometrySource(buffer:mesh.vertices.buffer, vertexFormat:mesh.vertices.format, semantic:.vertex,
                                         vertexCount:mesh.vertices.count, dataOffset:mesh.vertices.offset, dataStride:mesh.vertices.stride)
        var indices: [UInt32] = []
        for face in 0..<mesh.faces.count {
            guard let classes = mesh.classification else { continue }
            let raw = classes.buffer.contents().advanced(by:classes.offset + classes.stride*face).load(as:UInt8.self)
            let kind = ARMeshClassification(rawValue:Int(raw)) ?? .none
            // A reconstructed wall isn't exactly coplanar with the fitted plane.
            // Excluding wall/unknown faces prevents depth fighting over the paint.
            guard [.table,.seat,.door,.window,.floor,.ceiling].contains(kind) else { continue }
            for corner in 0..<mesh.faces.indexCountPerPrimitive {
                let offset = (face*mesh.faces.indexCountPerPrimitive+corner)*mesh.faces.bytesPerIndex
                let pointer = mesh.faces.buffer.contents().advanced(by:offset)
                indices.append(mesh.faces.bytesPerIndex == 2 ? UInt32(pointer.load(as:UInt16.self)) : pointer.load(as:UInt32.self))
            }
        }
        guard !indices.isEmpty else { occluders.removeValue(forKey:anchor.identifier)?.removeFromParentNode(); return }
        let geometry = SCNGeometry(sources:[vertices],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let depth = SCNMaterial(); depth.colorBufferWriteMask = []; depth.isDoubleSided = true
        depth.writesToDepthBuffer = true; depth.readsFromDepthBuffer = true
        geometry.materials = [depth]
        let node = occluders[anchor.identifier] ?? SCNNode()
        node.geometry = geometry; node.simdTransform = anchor.transform; node.renderingOrder = -100
        if node.parent == nil { view.scene.rootNode.addChildNode(node) }
        occluders[anchor.identifier] = node
    }
}

/// Render callbacks are on SceneKit's render thread. Publish only a one-second sample.
private final class WallRenderMeter: NSObject, ARSCNViewDelegate {
    private let lock = NSLock()
    private var count = 0
    private var start = ProcessInfo.processInfo.systemUptime
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); count += 1; lock.unlock()
    }
    func sample() -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let value = Int((Double(count)/max(0.01,now-start)).rounded())
        start = now; count = 0; return value
    }
}

private struct WallCameraView: UIViewRepresentable {
    let controller: WallARController
    func makeUIView(context: Context) -> ARSCNView { controller.view }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

@MainActor struct WallARStudio: View {
    @ObservedObject var model: RemoteAssistant
    @StateObject private var controller = WallARController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var help = false
    var body: some View {
        ZStack {
            WallCameraView(controller:controller).ignoresSafeArea(edges:.bottom)
            if !controller.selected {
                Image(systemName:"plus").font(.title.weight(.ultraLight)).foregroundStyle(.white)
                    .shadow(color:.black,radius:2).allowsHitTesting(false)
            }
            VStack(spacing:10) {
                HStack {
                    Label(controller.tracking ? "POSIÇÃO ESTÁVEL" : "MAPEANDO",systemImage:controller.tracking ? "viewfinder" : "viewfinder.circle")
                    Spacer()
                    Text(controller.metrics)
                }.font(.caption.monospaced()).padding(12).background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:14))
                Spacer()
                VStack(alignment:.leading,spacing:12) {
                    Text(controller.status).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:10) {
                            ForEach(WallFinish.allCases) { finish in
                                Button { controller.apply(.finish(finish)) } label: {
                                    VStack(spacing:5) {
                                        swatch(finish).frame(width:42,height:42).clipShape(RoundedRectangle(cornerRadius:10))
                                            .overlay(RoundedRectangle(cornerRadius:10).stroke(controller.finish == finish ? Color.cyan : Color.white.opacity(0.3),lineWidth:2))
                                        Text(finish.title).font(.caption2)
                                    }.frame(minWidth:60)
                                }.buttonStyle(.plain).disabled(!controller.prepared || controller.fatal)
                            }
                        }.padding(2)
                    }
                    HStack {
                        Button("Selecionar parede") { controller.apply(.select) }.disabled(!controller.tracking)
                        Spacer()
                        Button { controller.apply(.undo) } label: { Image(systemName:"arrow.uturn.backward") }.accessibilityLabel("Desfazer cor")
                        Button { controller.apply(.compare) } label: { Image(systemName:controller.comparing ? "eye.slash" : "eye") }.accessibilityLabel("Comparar original")
                        Button { help.toggle() } label: { Image(systemName:"info.circle") }.accessibilityLabel("Ajuda do modo AR")
                    }.buttonStyle(.bordered).controlSize(.small)
                    if !model.wakeEnabled {
                        Button("Ativar pedidos por voz") { model.setWakeEnabled(true) }.buttonStyle(.borderedProminent)
                    } else {
                        Text(model.followUp ? "Ouvindo · pode pedir outra cor" : "Diga: Oi Jarvis, deixa essa parede branca")
                            .font(.caption).foregroundStyle(.cyan)
                    }
                    if help {
                        Text("Mostre uma parede lisa, os cantos e o encontro com o teto. Toque nela ou diga “essa parede”. Depois: “agora azul”, “coloca madeira”, “desfaz” ou “mostra o original”.\n\nO recorte é aproximado: portas, quadros, espelhos e móveis pequenos podem não ficar perfeitos. A pintura dura nesta sessão. Se perder a posição, ela é ocultada até estabilizar.\n\nTexturas PBR 2K locais. A iluminação é aproximada; não preserva todas as sombras da parede real. Meta: 60 FPS, com redução térmica para 30 FPS.\n\n\(controller.notice)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:20))
            }.padding(12)
        }.background(.black).foregroundStyle(.white)
            .task {
                controller.onFeedback = { text in model.wallARFeedback(text) }
                await controller.start()
                consume()
            }
            .onChange(of:model.wallARRequest) { _,_ in consume() }
            .onChange(of:scenePhase) { _,phase in controller.setForeground(phase == .active) }
            .onDisappear { controller.stop() }
    }
    private func consume() {
        guard let request = model.wallARRequest else { return }
        model.wallARRequest = nil
        controller.apply(request.command)
    }
    @ViewBuilder private func swatch(_ finish: WallFinish) -> some View {
        if finish == .wood || finish == .concrete,
           let path = Bundle.main.path(forResource:"AR_\(finish.texture)_Color",ofType:"jpg"),
           let image = UIImage(contentsOfFile:path) { Image(uiImage:image).resizable().scaledToFill() }
        else { let (r,g,b) = finish.rgb; Color(red:r,green:g,blue:b) }
    }
}
