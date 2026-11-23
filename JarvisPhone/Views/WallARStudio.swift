import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import WebKit

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

enum WallMeasureMode { case none, outline, opening }

/// Owns one live ARSession. Painted geometry has its own world anchor and frozen
/// metric UVs, so plane refinement cannot stretch the texture or move its edges.
@MainActor final class WallARController: NSObject, ObservableObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {
    @Published var localizationTimedOut=false
    @Published var recoveryBusy=false
    @Published var savedMaps:[URL]=[]
    @Published var lensLabel="1×"
    private var prefersUltraWide=true
    private var recoveryTimer:Task<Void,Never>?
    private let coaching=ARCoachingOverlayView()
    @Published var measureMode = WallMeasureMode.none
    @Published var pointsCount = 0
    @Published var openingsCount = 0
    @Published var approved = false
    @Published var measuredArea: Float = 0
    @Published var measurement = ""
    var outline: [SIMD2<Float>] = []
    var draft: [SIMD2<Float>] = []
    var openings: [WallOpening] = []
    var markers = SCNNode()
    var automaticOpenings: [WallOpening] = []
    var paintRevision = 0
    var depthEvidence = WallDepthEvidence()
    var lastDepthUpdate: TimeInterval = 0
    var depthPending = false
    var spatial: SpatialWorld!
    var panel: SpatialPanel!
    var desktop: SpatialDesktop!
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
    var planes: [UUID:ARPlaneAnchor] = [:]
    var painted: SCNNode?
    var worldAnchor: ARAnchor?
    private var history: [WallFinish] = []
    private var occluders: [UUID:SCNNode] = [:]
    private var meshUpdated: [UUID:TimeInterval] = [:]
    let meshQueue = DispatchQueue(label:"jarvis.wall.occlusion",qos:.utility)
    private var pendingMeshes: Set<UUID> = []
    var materials: [WallFinish:SCNMaterial] = [:]
    private var gate = WallTrackingGate()
    var foreground = true
    private var started = false
    private var initialMap: ARWorldMap?
    private var mapStarted = false
    var stopped = false
    private var lastMetric: TimeInterval = 0
    private var cameraFrames = 0
    private var stableLight: CGFloat = 350
    private let light = SCNLight()
    private var performance = WallRenderMeter()
    private var lastFeedback: TimeInterval = 0
    var onFeedback: ((String) -> Void)?
    var webWindowVisible = false
    var hands:SpatialHands!
    @Published var handStatus="Mostre a mão à câmera traseira."
    private var palmRecall=SpatialPalmRecall()
    private var lastWindow="panel"

    override init() {
        super.init()
        view.scene = SCNScene()
        panel=SpatialPanel(view:view)
        spatial = SpatialWorld(view:view)
        desktop=SpatialDesktop(view:view)
        spatial.panelSnapshot = { [weak self] in self?.panel.snapshot() }
        spatial.desktopSnapshot = { [weak self] in self?.desktop.snapshot() }
        spatial.canSaveWindows = { [weak self] in
            guard let self else { return false }
            return !self.panel.isDragging && !self.desktop.isDragging
        }
        panel.onChange = { [weak self] in self?.spatial.markDirty();self?.lastWindow="panel" }
        desktop.onChange = { [weak self] in self?.spatial.markDirty();self?.lastWindow="desktop" }
        hands=SpatialHands(view:view)
        hands.onSample = { [weak self] sample in
            guard let self else { return }
            if self.desktop.inputBlocked { return }
            let palm=sample?.palmPoint ?? sample?.point
            let over=palm.map { self.panel.contains($0) || self.desktop.contains($0) } ?? false
            let candidate: String?
            if self.lastWindow == "desktop",self.desktop.visible { candidate=self.desktop.isFramed ? nil : "desktop" }
            else if self.panel.visible { candidate=self.panel.isFramed ? nil : "panel" }
            else if self.desktop.visible { candidate=self.desktop.isFramed ? nil : "desktop" }
            else { candidate=nil }
            if let target=self.palmRecall.update(open:sample?.openPalm == true && self.tracking && !self.spatial.recovering,target:candidate,overInterface:over,time:sample?.time ?? ProcessInfo.processInfo.systemUptime) {
                if target == "desktop" { self.desktop.recenter() } else { self.panel.reposition() }
                self.handStatus="Janela reenquadrada. Relaxe a mão para continuar."
            }
            if self.palmRecall.progress>0 || self.palmRecall.hasFired {
                self.hands.showProgress(self.palmRecall.progress);return
            }
            if self.desktop.hand(sample) { self.hands.showProgress(self.desktop.progress);return }
            if self.panel.visible { self.panel.hand(sample) } else { self.spatial.hand(sample) }
            self.hands.showProgress(self.panel.visible ? self.panel.dwellProgress : self.spatial.dwellProgress)
        }
        hands.onQuality = { [weak self] in self?.handStatus=$0 }
        spatial.attach()
        spatial.onAttackRequest = { [weak self] in self?.requestWallAttack() }
        spatial.onImpact = { [weak self] point in self?.showWallImpact(point) }
        view.session.delegate = self
        view.session.delegateQueue = .main
        coaching.session=view.session;coaching.goal = .tracking;coaching.activatesAutomatically=true;coaching.delegate=self
        coaching.autoresizingMask=[.flexibleWidth,.flexibleHeight];coaching.frame=view.bounds;view.insertSubview(coaching,at:0)
        view.delegate = performance
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        light.type = .ambient; light.intensity = stableLight
        let node = SCNNode(); node.light = light
        view.scene.rootNode.addChildNode(node)
        UIDevice.current.isBatteryMonitoringEnabled=true
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
        do { initialMap = try await spatial.loadMap() }
        catch {
            status="Não consegui ler o mapa salvo. Ele foi preservado. Escolha outro mapa ou inicie um novo."
            localizationTimedOut=true;savedMaps=SpatialArchive.savedMaps()
        }
        // Decode and upload once, before scanning; no image generation or downloading
        // competes with tracking. Shared PBR textures use metric UVs and mipmaps.
        for f in WallFinish.allCases { materials[f] = WallMaterials.make(f) }
        for id in ["mossrock","fern","radio"] {
            do { _ = try SpatialAssets.load(id) }
            catch { notice = "Modelo local indisponível: \(id)." }
            await Task.yield()
        }
        view.prepare(Array(materials.values)) { [weak self] ready in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.prepared = ready
                self.started = true
                if self.foreground && !self.localizationTimedOut { self.run() }
            }
        }
    }

    private func run(reset: Bool = false) {
        guard foreground, !stopped, !fatal else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal,.vertical]
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if !mapStarted || reset { config.initialWorldMap=initialMap;mapStarted=true }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        // Prefer moderate camera resolution at 60 Hz rather than 4K capture + AI.
        let available=ARWorldTrackingConfiguration.supportedVideoFormats
        let ultra=available.filter { $0.captureDevicePosition == .back && $0.captureDeviceType == .builtInUltraWideCamera }
        let candidates=prefersUltraWide && !ultra.isEmpty ? ultra : available.filter { $0.captureDeviceType == .builtInWideAngleCamera }
        let fast=candidates.filter { $0.framesPerSecond == 60 }
        if let format=(fast.isEmpty ? candidates : fast).min(by:{$0.imageResolution.width<$1.imageResolution.width}) {
            config.videoFormat=format;lensLabel=format.captureDeviceType == .builtInUltraWideCamera ? "0,5×" : "1×"
        }
        if prefersUltraWide && ultra.isEmpty { notice="A câmera 0,5× não foi oferecida pelo ARKit nesta configuração. A sessão usa \(lensLabel)." }
        view.session.run(config,options:reset ? [.resetTracking,.removeExistingAnchors] : [])
        view.isPlaying = true
        armRecoveryTimer()
    }

    func selectLens(ultra: Bool) {
        guard !recoveryBusy else { return }
        if ultra && !ARWorldTrackingConfiguration.supportedVideoFormats.contains(where:{$0.captureDeviceType == .builtInUltraWideCamera && $0.captureDevicePosition == .back}) {
            notice="O iOS não disponibilizou 0,5× para esta sessão AR com LiDAR.";return
        }
        prefersUltraWide=ultra;spatial.stopMoving();hands.reset();spatial.requireSurfaceConfirmation();run()
    }

    private func armRecoveryTimer() {
        guard recoveryTimer == nil,(!tracking || spatial.recovering) else { return }
        recoveryTimer=Task { [weak self] in
            try? await Task.sleep(for:.seconds(20))
            guard !Task.isCancelled,let self,!self.stopped,(!self.tracking || self.spatial.recovering) else { return }
            self.localizationTimedOut=true;self.status="O mapa ainda não foi reencontrado. Tente o mapa salvo ou inicie outro mapeamento."
            self.savedMaps=await Task.detached { SpatialArchive.savedMaps() }.value
            self.recoveryTimer=nil
        }
    }

    func changeMap(restore source: URL?) {
        guard started,!recoveryBusy else { return };recoveryBusy=true;localizationTimedOut=false
        recoveryTimer?.cancel();recoveryTimer=nil
        spatial.stopMoving();view.session.pause();tracking=false;_ = gate.update(normal:false,at:0);setVisible(false);desktop.setTracking(false)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.spatial.prepareMapChange(restore:source)
                guard !self.stopped else { self.spatial.finishMapChange();return }
                self.panel.close(recordChange:false);self.desktop.close(recordChange:false);self.clear(silent:true)
                self.spatial.resetLiveScene(newWorld:source == nil)
                self.occluders.values.forEach { $0.removeFromParentNode() };self.occluders.removeAll();self.planes.removeAll();self.meshUpdated.removeAll()
                self.initialMap=source == nil ? nil : try await self.spatial.loadMap()
                self.mapStarted=false;self.fatal=false;self.recoveryBusy=false;self.spatial.finishMapChange()
                self.status=source == nil ? "Novo mapeamento. Mostre piso, cantos e detalhes das paredes." : "Reconhecendo o mapa salvo. Volte ao ambiente onde ele foi gravado."
                if !self.stopped { self.run(reset:true) }
            } catch {
                self.recoveryBusy=false;self.spatial.finishMapChange();self.localizationTimedOut=true
                self.status="Não consegui restaurar esse mapa. \(error.localizedDescription)"
            }
            self.savedMaps=await Task.detached { SpatialArchive.savedMaps() }.value
        }
    }

    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        localizationTimedOut=true;coachingOverlayView.setActive(false,animated:true)
        savedMaps=SpatialArchive.savedMaps()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active && started && !recoveryBusy && !localizationTimedOut { run() }
        else if !active {
            recoveryTimer?.cancel();recoveryTimer=nil
            spatial.stopMoving()
            spatial.saveMap(force:false)
            spatial.requireSurfaceConfirmation()
            desktop.setTracking(false)
            view.session.pause(); view.isPlaying = false
            tracking = false; _ = gate.update(normal:false, at:0); setVisible(false)
        }
    }

    func stop() {
        recoveryTimer?.cancel();recoveryTimer=nil
        spatial.saveMap(force:false)
        stopped = true
        hands.reset()
        view.session.pause(); view.isPlaying = false
        view.session.delegate = nil; view.delegate = nil
        onFeedback = nil
        panel.close(recordChange:false)
        desktop.close(recordChange:false)
        spatial.stop()
        materials.removeAll(); occluders.removeAll(); planes.removeAll()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point=gesture.location(in:view)
        if desktop.tap(point) { return }
        if panel.visible { _=panel.hit(point);return }
        if measureMode != .none { addPoint(at:point) }
        else if spatial.active { spatial.tap(point,tracking:tracking) }
        else { select(at:point) }
    }

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
        clear(silent:true)
        spatial.active=false
        let root=SCNNode(); root.simdTransform=plane.transform
        let surface=SCNNode()
        if let frame=view.session.currentFrame {
            let localCamera=simd_inverse(plane.transform) * frame.camera.transform.columns.3
            surface.position.y=localCamera.y>=0 ? 0.025 : -0.025
        }
        root.addChildNode(surface)
        markers=SCNNode(); markers.position.y=surface.position.y*1.3; root.addChildNode(markers)
        let anchor=ARAnchor(name:"JarvisMeasuredWall",transform:plane.transform)
        worldAnchor=anchor; painted=root
        view.scene.rootNode.addChildNode(root); view.session.add(anchor:anchor)
        selected=true; comparing=false; history=[]; approved=false
        outline=[]; draft=[]; openings=[]; pointsCount=0; openingsCount=0
        measureMode = .outline
        status="Marque os cantos em ordem com a mira e Adicionar ponto. A parede ainda não foi pintada."
        notice="Exclua portas, janelas e armários antes de Aplicar. Regiões sem profundidade confiável ficam sem pintura."
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
        guard !recoveryBusy else { return }
        switch command {
        case .open: break
        case .select:
            if select() { feedback("Marque os cantos da parede e as áreas que devem ficar livres.") }
            else { feedback(status) }
        case .finish(let value):
            let old = finish
            finish = value
            if selected && approved {
                if old != value { history.append(old); if history.count > 20 { history.removeFirst() } }
                painted?.childNodes.first?.geometry?.materials = [materials[value] ?? WallMaterials.make(value)]
                comparing = false; setVisible(tracking)
                status = "\(value.title) aplicado à mesma parede."
                feedback(status)
            } else {
                status="\(value.title) escolhido. Marque a parede e as exclusões; depois toque em Aplicar."
                feedback(status)
            }
        case .undo:
            guard let previous = history.popLast() else { feedback("Não há outra cor para desfazer nesta parede."); return }
            finish = previous; painted?.childNodes.first?.geometry?.materials = [materials[previous] ?? WallMaterials.make(previous)]
            comparing = false; setVisible(tracking); status = "Voltei para \(previous.title)."; feedback(status)
        case .clear: clear(); feedback("Pintura removida.")
        case .compare: comparing.toggle(); setVisible(tracking && !comparing); status = comparing ? "Parede original." : "Pintura AR." 
        case .panel(let module): panel.open(module,tracking:tracking)
        case .navigate(let text): panel.interpret(text)
        case .measure: beginOutline()
        case .point: addPoint()
        case .opening: beginOpening()
        case .approve: confirm()
        case .theme(let theme): measureMode = .none; spatial.setTheme(theme)
        case .interact: spatial.interact()
        case .removeObject: spatial.removeSelected()
        case .model(let id): measureMode = .none;spatial.setModel(id)
        case .resizeObject(let factor): spatial.resizeSelected(factor)
        case .moveObject(let x,let z): spatial.moveSelected(x:x,z:z)
        case .saveMap: spatial.saveMap()
        case .room(let name): spatial.chooseRoom(name)
        case .desktop: desktop.open(tracking:tracking)
        case .character(let action):
            if action == "walk" { spatial.walk() }
            else if action == "stop" { spatial.stopMoving() }
            else if action == "impact" { requestWallAttack() }
            else if action == "repair" { repairWall() }
            else { spatial.animate(action) }
        case .close: break
        }
    }

    func feedback(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastFeedback > 0.8 else { return }
        lastFeedback = now; onFeedback?(text)
    }
    private func clear(silent: Bool = false) {
        if let anchor = worldAnchor { view.session.remove(anchor:anchor) }
        worldAnchor = nil; painted?.removeFromParentNode(); painted = nil
        selected=false; approved=false; comparing=false; history.removeAll()
        measureMode = .none; outline=[]; draft=[]; openings=[]; paintRevision += 1
        depthEvidence=WallDepthEvidence(); pointsCount=0; openingsCount=0; measuredArea=0; measurement=""
        if !silent { status = "Pintura removida. Escolha outra parede." }
    }
    private func setVisible(_ visible: Bool) {
        // No fade, camera tween, flashing reticle or screen-space fallback.
        // Gate has a dwell time, preventing normal/limited oscillation flicker.
        painted?.isHidden = !visible
        spatial.setVisible(visible)
        panel.setTracking(visible)
        if !visible { hands.reset() }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard foreground, !stopped,!recoveryBusy else { return }
        let normal: Bool
        switch frame.camera.trackingState { case .normal: normal = true; default: normal = false }
        let good = gate.update(normal:normal, at:frame.timestamp)
        if good && !spatial.recovering { recoveryTimer?.cancel();recoveryTimer=nil;localizationTimedOut=false }
        spatial.persistenceTick(frame)
        spatial.setVisible(good && !comparing)
        if good && !comparing { spatial.validateSupports(frame) }
        if good && !comparing { spatial.stepSimulation(frame.timestamp) }
        panel.setTracking(good)
        desktop.setTracking(good && !spatial.recovering)
        hands.update(frame,view:view,enabled:good && !webWindowVisible && (panel.visible || spatial.active || desktop.visible))
        if tracking != good {
            tracking = good; setVisible(good && !comparing)
            status = good ? (selected ? "Parede fixada. Pode mudar o material por voz." : "Toque na parede ou diga “essa parede”.") : "Recuperando posição. Mova devagar e mostre detalhes do ambiente."
        }
        if good,spatial.objectCount>0,!spatial.supportsConfirmed { status=spatial.persistenceStatus }
        if approved && good && frame.timestamp-lastDepthUpdate>0.5 { updateDepth(frame) }
        cameraFrames += 1
        if frame.timestamp-lastMetric >= 1 {
            let fps = performance.sample()
            spatial.recordPerformance(fps:fps,frame:frame,handLatencyMS:hands.latencyMS,handFound:hands.hasHand,handDepth:hands.hasDepth)
            metrics = fps > 0 ? "\(fps) FPS · LiDAR · local" : "LiDAR · renderização local"
            lastMetric = frame.timestamp; cameraFrames = 0
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical {
                fatal = true; setVisible(false); view.session.pause(); view.isPlaying = false
                status = "iPhone quente. AR pausado; feche e deixe o aparelho esfriar."; return
            }
            spatial.setThermal(thermal)
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
            if anchor.identifier == worldAnchor?.identifier { worldAnchor=anchor; painted?.simdTransform = anchor.transform }
            if let plane = anchor as? ARPlaneAnchor {
                planes[plane.identifier]=plane
                if approved && (plane.classification == .door || plane.classification == .window) { refreshAutomaticOpenings() }
            }
            panel.update(anchor)
            desktop.update(anchor)
            if let saved=spatial.restoredDesktop,saved.anchor==anchor.identifier {
                desktop.restore(saved,anchor:anchor);spatial.restoredDesktop=nil
            }
            if let saved=spatial.restoredPanel,saved.anchor==anchor.identifier {
                panel.restore(saved,anchor:anchor);spatial.restoredPanel=nil
            }
            spatial.update(anchor)
            if let mesh = anchor as? ARMeshAnchor { updateOccluder(mesh) }
        }
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            spatial.remove(anchor)
            planes.removeValue(forKey:anchor.identifier)
            occluders.removeValue(forKey:anchor.identifier)?.removeFromParentNode()
            meshUpdated.removeValue(forKey:anchor.identifier)
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        spatial.requireSurfaceConfirmation()
        tracking = false; _ = gate.update(normal:false,at:0); setVisible(false)
        status = "AR interrompido. A pintura reaparece após recuperar a posição."
    }
    func sessionInterruptionEnded(_ session: ARSession) { if foreground { run() } }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func session(_ session: ARSession,cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            if !spatial.recovering { recoveryTimer?.cancel();recoveryTimer=nil;localizationTimedOut=false }
        default:
            spatial.requireSurfaceConfirmation()
            tracking=false;_ = gate.update(normal:false,at:0);setVisible(false)
            status="Relocalizando. Volte ao ambiente anterior e mostre o piso e detalhes das paredes."
            armRecoveryTimer()
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        fatal = true; setVisible(false); status = "AR indisponível: \(error.localizedDescription). Feche e reabra este modo."
    }

    private func updateOccluder(_ anchor: ARMeshAnchor) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now-(meshUpdated[anchor.identifier] ?? 0) > 0.5 else { return }
        guard occluders[anchor.identifier] != nil || occluders.count < 48 else { return }
        guard pendingMeshes.count < 4, !pendingMeshes.contains(anchor.identifier) else { return }
        meshUpdated[anchor.identifier] = now
        pendingMeshes.insert(anchor.identifier)
        // Do not enumerate/rebuild LiDAR triangles on the UI/rendering thread.
        // Bounded pending work drops intermediate meshes instead of accumulating lag.
        meshQueue.async { [weak self] in
            let geometry = Self.occlusionGeometry(anchor.geometry)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingMeshes.remove(anchor.identifier)
                guard !self.stopped, self.meshUpdated[anchor.identifier] != nil else { return }
                guard let geometry else { self.occluders.removeValue(forKey:anchor.identifier)?.removeFromParentNode(); return }
                let node = self.occluders[anchor.identifier] ?? SCNNode()
                node.geometry = geometry; node.simdTransform = anchor.transform; node.renderingOrder = -100;node.categoryBitMask=2
                if node.parent == nil { self.view.scene.rootNode.addChildNode(node) }
                self.occluders[anchor.identifier] = node
            }
        }
    }

    nonisolated private static func occlusionGeometry(_ mesh: ARMeshGeometry) -> SCNGeometry? {
        let vertices = SCNGeometrySource(buffer:mesh.vertices.buffer, vertexFormat:mesh.vertices.format, semantic:.vertex,
                                         vertexCount:mesh.vertices.count, dataOffset:mesh.vertices.offset, dataStride:mesh.vertices.stride)
        var indices: [UInt32] = []
        for face in 0..<mesh.faces.count {
            guard let classes = mesh.classification else { continue }
            let raw = classes.buffer.contents().advanced(by:classes.offset + classes.stride*face).load(as:UInt8.self)
            let kind = ARMeshClassification(rawValue:Int(raw)) ?? .none
            // Walls and unclassified foreground also occlude spatial objects.
            // Paint is offset and independently gated by observed scene depth.
            guard [.wall,.none,.table,.seat,.door,.window,.floor,.ceiling].contains(kind) else { continue }
            for corner in 0..<mesh.faces.indexCountPerPrimitive {
                let offset = (face*mesh.faces.indexCountPerPrimitive+corner)*mesh.faces.bytesPerIndex
                let pointer = mesh.faces.buffer.contents().advanced(by:offset)
                indices.append(mesh.faces.bytesPerIndex == 2 ? UInt32(pointer.load(as:UInt16.self)) : pointer.load(as:UInt32.self))
            }
        }
        guard !indices.isEmpty else { return nil }
        let geometry = SCNGeometry(sources:[vertices],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let depth = SCNMaterial(); depth.colorBufferWriteMask = []; depth.isDoubleSided = true
        depth.writesToDepthBuffer = true; depth.readsFromDepthBuffer = true
        geometry.materials = [depth]
        return geometry
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

@MainActor private struct SpatialRecoveryControls: View {
    @ObservedObject var controller: WallARController
    @State private var confirmNew=false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Recuperar ambiente",systemImage:"map.fill").font(.headline)
            Text(controller.status).font(.caption)
            Text("Volte ao local original. Mostre piso, cantos e detalhes das paredes, movendo o celular devagar. Evite apontar só para uma parede lisa.").font(.caption)
            if controller.recoveryBusy { ProgressView("Preparando mapa…") }
            else {
                HStack {
                    Button("Tentar mapa salvo") { controller.changeMap(restore:SpatialArchive.file) }
                        .disabled(!FileManager.default.fileExists(atPath:SpatialArchive.file.path))
                    Button("Novo mapa") { confirmNew=true }
                }.buttonStyle(.bordered).controlSize(.small)
                Menu("Restaurar outro mapa (\(controller.savedMaps.count))") {
                    ForEach(controller.savedMaps,id:\.self) { url in
                        Button(mapTitle(url)) { controller.changeMap(restore:url) }
                    }
                }.disabled(controller.savedMaps.isEmpty)
            }
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
        .confirmationDialog("Iniciar outro ambiente?",isPresented:$confirmNew,titleVisibility:.visible) {
            Button("Guardar mapa antigo e começar outro") { controller.changeMap(restore:nil) }
            Button("Cancelar",role:.cancel) {}
        } message: {
            Text("O mapa anterior ficará em Restaurar outro mapa. Os objetos dele não serão colocados em coordenadas erradas no novo ambiente.")
        }
    }
    private func mapTitle(_ url: URL) -> String {
        let date=(try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (url == SpatialArchive.file ? "Atual · " : "Guardado · ")+date.formatted(date:.abbreviated,time:.shortened)
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
    @State private var objectsTab = false
    @State private var panelVisible = false
    @State private var webModule: SpatialModule?
    @State private var panelStatus = ""
    @State private var menuSheet: SpatialSheet?
    @State private var search = ""
    @State private var confirmAction: PhoneAction?
    var body: some View {
        ZStack {
            WallCameraView(controller:controller).ignoresSafeArea(edges:.bottom).allowsHitTesting(webModule == nil && !controller.recoveryBusy)
            if !panelVisible && (!controller.selected || controller.measureMode != .none) {
                Image(systemName:"plus").font(.title.weight(.ultraLight)).foregroundStyle(.white)
                    .shadow(color:.black,radius:2).allowsHitTesting(false)
            }
            if let webModule {
                SpatialWebWindow(module:webModule) { self.webModule=nil;controller.panel.open(.dashboard,tracking:controller.tracking) }.id(webModule.rawValue)
            } else {
            VStack(spacing:10) {
                HStack {
                    Label(controller.tracking ? "POSIÇÃO ESTÁVEL" : "MAPEANDO",systemImage:controller.tracking ? "viewfinder" : "viewfinder.circle")
                    Spacer()
                    Button { controller.panel.open(.dashboard,tracking:controller.tracking) } label: { Image(systemName:"square.grid.2x2") }
                    Button { controller.desktop.open(tracking:controller.tracking) } label: { Image(systemName:"desktopcomputer") }.accessibilityLabel("Abrir tela do PC em AR")
                    Button { controller.panel.reposition() } label: { Image(systemName:"scope") }.accessibilityLabel("Trazer painel para frente")
                    Menu(controller.lensLabel) {
                        Button("0,5× · ultra-angular") { controller.selectLens(ultra:true) }
                        Button("1× · principal") { controller.selectLens(ultra:false) }
                    }
                    Button { controller.localizationTimedOut.toggle();controller.savedMaps=SpatialArchive.savedMaps() } label: { Image(systemName:"map") }.accessibilityLabel("Recuperar mapa")
                }.font(.caption.monospaced()).padding(12).background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:14))
                Text(controller.metrics).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if controller.localizationTimedOut || controller.recoveryBusy {
                    SpatialRecoveryControls(controller:controller)
                }
                Spacer()
                SpatialDesktopControls(desktop:controller.desktop)
                if panelVisible {
                    VStack(alignment:.leading,spacing:6) {
                        Text(panelStatus).font(.caption).lineLimit(3)
                        Text(controller.handStatus).font(.caption2).foregroundStyle(.cyan)
                        Text("Indicador por 2 s clica. Pinça move. Palma sobre a janela: aproxime para aumentar, afaste para diminuir. Palma fora por 1 s traz a janela desenquadrada. Dois dedos em V viram a página.").font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Todos os módulos",systemImage:"list.bullet") { search="";menuSheet = .directory }
                            Button("Menor",systemImage:"minus.magnifyingglass") { controller.panel.resize(0.82) }
                            Button("Centralizar",systemImage:"scope") { controller.panel.reposition() }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:14))
                } else {
                VStack(alignment:.leading,spacing:12) {
                    Picker("Ferramenta",selection:$objectsTab) {
                        Text("Medir e pintar").tag(false)
                        Text("Cenários 3D").tag(true)
                    }.pickerStyle(.segmented)
                    if objectsTab {
                        SpatialControls(world:controller.spatial)
                    } else {
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
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack {
                            Button("Marcar parede",systemImage:"ruler") { controller.beginOutline() }.disabled(!controller.tracking)
                            Button("Adicionar ponto",systemImage:"plus.circle.fill") { controller.addPoint() }.disabled(controller.measureMode == .none || !controller.tracking)
                            Button("Excluir área",systemImage:"rectangle.dashed") { controller.beginOpening() }.disabled(!controller.selected)
                            Button("Desfazer ponto",systemImage:"arrow.uturn.backward") { controller.undoPoint() }
                            Button("Aplicar",systemImage:"checkmark") { controller.confirm() }.disabled(!controller.tracking || !controller.selected)
                            Button { controller.apply(.compare) } label: { Image(systemName:controller.comparing ? "eye.slash" : "eye") }.accessibilityLabel("Comparar original")
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Text("\(controller.pointsCount) pontos · \(controller.openingsCount) exclusões · \(controller.measurement)").font(.caption2).foregroundStyle(.cyan)
                    }
                    Button(help ? "Ocultar ajuda" : "Como marcar e interagir") { help.toggle() }.font(.caption)
                    if !model.wakeEnabled {
                        Button("Ativar pedidos por voz") { model.setWakeEnabled(true) }.buttonStyle(.borderedProminent)
                    } else {
                        Text(model.followUp ? "Ouvindo · pode pedir outra cor" : "Diga: Oi Jarvis, deixa essa parede branca")
                            .font(.caption).foregroundStyle(.cyan)
                    }
                    if help {
                        Text("Marcar parede → aponte a mira para cada canto → Adicionar ponto. Siga o contorno em ordem. Excluir área: marque dois cantos opostos de cada porta, janela ou armário. Confira as linhas e toque em Aplicar.\n\nA pintura só aparece onde duas leituras de profundidade confirmam a parede. Áreas desconhecidas ficam vazias: mostre de outro ângulo. Coplanaridade não identifica uma porta fechada; marque a exclusão.\n\nCenários: escolha um dos seis cenários ou abra o catálogo de 20 objetos, toque no piso/mesa mapeados. Toque no objeto para selecionar e novamente para interagir. Arraste, use pinça e gire com dois dedos.\n\nUse Remover para liberar uma passagem. As medidas são estimativas. Não detecta automaticamente todos os armários ou batentes.\n\nModelos: Poly Haven e autores do catálogo Khronos. Créditos e licenças CC0/CC BY incluídos. Meta de 60 FPS, redução térmica para 30. \(controller.notice)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:20))
                }
            }.padding(12)
            }
        }.background(.black).foregroundStyle(.white)
            .task {
                controller.onFeedback = { text in model.wallARFeedback(text) }
                controller.panel.onWeb = { target in
                    controller.spatial.hand(nil)
                    controller.hands.reset()
                    controller.webWindowVisible=true
                    webModule=target
                }
                controller.panel.onSpotify = { job in model.requestSpatialSpotify(job) }
                controller.desktop.send = { job in model.requestDesktop(job) }
                controller.panel.onAction = { action in
                    switch action {
                    case .editor(let sheet): menuSheet=sheet
                    case .instrument(let instrument):
                        if model.openStudio("music",instrument:instrument) { controller.panel.close() }
                    case .wall(let command):
                        if command == .saveMap { controller.apply(command);return }
                        objectsTab=false;controller.panel.close();controller.apply(command)
                    case .systemAction(let action):
                        if [.wifiOff,.bluetoothOff,.cellularOff,.lock].contains(action) { confirmAction=action }
                        else { runPhoneAction(action) }
                    case .activateSpotify: model.showSpotify()
                    case .model(let id): objectsTab=true;controller.spatial.setModel(id);controller.panel.close()
                    case .scene(let theme): objectsTab=true;controller.spatial.setTheme(theme);controller.panel.close()
                    case .studio(let mode): controller.panel.close();model.openStudio(mode)
                    case .command(let text): Task { await model.runSpatialCommand(text) }
                    default: break
                    }
                }
                await controller.start()
                consume()
            }
            .sheet(item:$menuSheet) { sheet in
                switch sheet {
                case .note: NoteEditor(controller:.shared)
                case .notes: NotesView(controller:.shared)
                case .reminder: ReminderEditor(controller:.shared)
                case .directory:
                    NavigationStack {
                        let results=controller.panel.directory(search)
                        List {
                            ForEach(results) { result in
                                Button {
                                    menuSheet=nil
                                    controller.panel.open(result.module,tracking:controller.tracking,page:result.page)
                                } label: {
                                    VStack(alignment:.leading) {
                                        Label(result.module.title,systemImage:result.module.symbol)
                                        if result.title != result.module.title { Text(result.title).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            if results.isEmpty { Text("Nenhum módulo ou ação com esse nome.") }
                        }.navigationTitle("Todos os módulos")
                        .searchable(text:$search,prompt:"Buscar módulo ou ação")
                        .toolbar { Button("Fechar") { menuSheet=nil } }
                    }
                }
            }
            .confirmationDialog("Confirmar no iPhone?",isPresented:Binding(get:{ confirmAction != nil },set:{ if !$0 { confirmAction=nil } }),presenting:confirmAction) { action in
                Button(action.title) { runPhoneAction(action) }
                Button("Cancelar",role:.cancel) {}
            }
            .onChange(of:menuSheet) { _,_ in syncOverlay() }
            .onChange(of:confirmAction) { _,_ in syncOverlay() }
            .onChange(of:objectsTab) { _,active in
                controller.spatial.active=active
                if active { controller.measureMode = .none }
            }
            .onChange(of:model.wallARRequest) { _,_ in consume() }
            .onChange(of:webModule) { _,target in
                syncOverlay()
            }
            .onReceive(controller.panel.$visible) { panelVisible=$0;controller.spatial.panelBlocking=$0 || overlayVisible }
            .onReceive(controller.panel.$status) { panelStatus=$0 }
            .onChange(of:model.spatialPanelResponse) { _,data in if let data { controller.panel.receive(data) } }
            .onChange(of:model.desktopResponse) { _,data in if let data { controller.desktop.receive(data) } }
            .onChange(of:model.message) { _,text in controller.panel.showResult(text) }
            .onChange(of:scenePhase) { _,phase in controller.setForeground(phase == .active) }
            .onDisappear { controller.stop() }
    }
    private var overlayVisible: Bool { webModule != nil || menuSheet != nil || confirmAction != nil }
    private func syncOverlay() {
        controller.webWindowVisible=overlayVisible
        controller.spatial.panelBlocking=overlayVisible || panelVisible
        if overlayVisible { controller.hands.reset() }
    }
    private func runPhoneAction(_ action:PhoneAction) {
        Task {
            let phone=PhoneController.shared
            await phone.run(action)
            controller.panel.showResult(phone.message)
        }
    }
    private func consume() {
        guard let request = model.wallARRequest else { return }
        model.wallARRequest = nil
        if case .panel(let target) = request.command {
            if target == .youtube || target == .browser { controller.panel.open(target,tracking:controller.tracking);return }
            webModule=nil
        }
        if case .theme = request.command { objectsTab=true }
        if case .model = request.command { objectsTab=true }
        if case .panel = request.command, !controller.tracking {
            // Opening a panel by voice must wait for AR tracking, not consume the request.
            Task { @MainActor in
                for _ in 0..<80 {
                    try? await Task.sleep(for:.milliseconds(100))
                    if controller.stopped { return }
                    if controller.tracking { controller.apply(request.command);return }
                }
                controller.status="Não consegui fixar o painel. Mostre detalhes do ambiente e tente novamente."
            }
            return
        }
        controller.apply(request.command)
    }
    @ViewBuilder private func swatch(_ finish: WallFinish) -> some View {
        if finish == .wood || finish == .concrete,
           let path = Bundle.main.path(forResource:"AR_\(finish.texture)_Color",ofType:"jpg"),
           let image = UIImage(contentsOfFile:path) { Image(uiImage:image).resizable().scaledToFill() }
        else { let (r,g,b) = finish.rgb; Color(red:r,green:g,blue:b) }
    }
}

/// A screen-relative media window stays reachable when looking straight up.
@MainActor private struct SpatialWebWindow: View {
    let module: SpatialModule
    let close: () -> Void
    @State private var address = ""
    @State private var destination: URL?
    var body: some View {
        VStack(spacing:8) {
            HStack {
                Label(module.title,systemImage:module.symbol).font(.headline)
                Spacer()
                Button("Voltar ao painel",action:close)
            }
            HStack {
                TextField(module == .youtube ? "Buscar vídeo" : "Endereço ou busca",text:$address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit(search)
                Button("Ir",action:search)
            }.textFieldStyle(.roundedBorder)
            SpatialWebContent(url:destination ?? URL(string:module == .youtube ? "https://m.youtube.com/" : "https://duckduckgo.com/")!)
                .frame(maxHeight:360).clipShape(RoundedRectangle(cornerRadius:12))
        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(12)
    }
    private func search() {
        let query = address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if module == .browser, !query.contains(" "), query.contains("."),
           let url=URL(string:query.contains("://") ? query : "https://"+query),url.scheme=="https",url.host != nil {
            destination=url;return
        }
        var parts=URLComponents(string:module == .youtube ? "https://m.youtube.com/results" : "https://duckduckgo.com/")!
        parts.queryItems=[URLQueryItem(name:module == .youtube ? "search_query" : "q",value:query)]
        destination=parts.url
    }
}
private struct SpatialWebContent: UIViewRepresentable {
    let url:URL
    final class Coordinator: NSObject, WKNavigationDelegate {
        var requested:URL?
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            guard let url=action.request.url else { decisionHandler(.cancel);return }
            if action.targetFrame?.isMainFrame != false && url.scheme != "https" { decisionHandler(.cancel);return }
            if action.targetFrame == nil { decisionHandler(.cancel);webView.load(action.request);return }
            decisionHandler(.allow)
        }
    }
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeUIView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback=true
        let web=WKWebView(frame:.zero,configuration:config)
        web.navigationDelegate=context.coordinator
        web.allowsBackForwardNavigationGestures=true
        return web
    }
    func updateUIView(_ web:WKWebView,context:Context) {
        guard context.coordinator.requested != url else { return }
        context.coordinator.requested=url;web.load(URLRequest(url:url))
    }
    static func dismantleUIView(_ web:WKWebView,coordinator:Coordinator) {
        web.pauseAllMediaPlayback {};web.stopLoading()
    }
}
