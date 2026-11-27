import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import WebKit
import CoreLocation

struct WallARRequest: Equatable {
    let id = UUID()
    let command: WallARCommand
}

enum WallMaterials {
    private static var images: [String: UIImage] = [:]
    static func effect(_ style:String)->SCNMaterial {
        let m=make(.white)
        guard style=="brick" else { return m }
        m.multiply.contents=UIColor.white
        for (prop,key) in [(m.diffuse,"Color"),(m.normal,"NormalGL"),(m.roughness,"Roughness")] {
            let name="RoomFX_brick_"+key
            if images[name]==nil,let path=Bundle.main.path(forResource:name,ofType:"jpg") { images[name]=UIImage(contentsOfFile:path) }
            prop.contents=images[name];prop.contentsTransform=SCNMatrix4MakeScale(1/3,1/3,1)
        }
        m.normal.intensity=0.5;return m
    }
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
    @Published var scanning=false
    @Published var headset=false
    @Published var headsetStatus="Preparando visor"
    private var dualScale=SpatialDualPinchScale()
    private var dualScaleTarget:String?
    private var touchScaleTarget:String?
    private let mapLocation=LocationService(accuracy:kCLLocationAccuracyNearestTenMeters)
    private var locationTask:Task<Void,Never>?
    private var desktopResume=SpatialDesktopResumeIntent()
    private var desktopResumeScale:Float=0.7
    private(set) var videoRunning=false
    var onHeadsetFrame:((ARFrame)->Void)?
    private var interactionReady=false
    private var poseStability=SpatialPoseStability()
    private var activeVideoFormat: ARConfiguration.VideoFormat?
    private var frameLink:CADisplayLink?
    private var frameInput=SpatialFrameGate()
    private var scanTask:Task<Void,Never>?
    private var prefersUltraWide=true
    private var recoveryTimer:Task<Void,Never>?
    private var recoveryDelay:Duration = .seconds(20)
    private var pendingMapReset=false
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
    var roomWall:ScannedRoomWall!
    var liveWall:LiveWallEffect!
    var portal:SpatialWallPortal!
    private var savedMapSuspended=false
    private var portalRequested=false
    @Published var roomSetupPresented=false
    private var fistMenu=SpatialFistMenuGesture()
    @Published var status = "Ambiente fixo. Escaneie somente para ler uma nova superfície."
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
        roomWall=ScannedRoomWall(view:view)
        portal=SpatialWallPortal(view:view)
        portal.onChange = { [weak self] in self?.spatial.markDirty() }
        portal.onFeedback = { [weak self] in self?.feedback($0) }
        spatial.portalSnapshot = { [weak self] in self?.portal.snapshot() }
        liveWall=LiveWallEffect(view:view)
        liveWall.onFeedback = { [weak self] in self?.feedback($0) }
        spatial.scannedRoomSnapshot = { [weak self] in self?.roomWall.snapshot() }
        roomWall.onChange = { [weak self] in self?.spatial.markDirty() }
        roomWall.onRegistered = { [weak self] in
            guard let self else { return }
            self.scanTask?.cancel();self.scanTask=nil;self.scanning=false;self.run()
            self.roomWall.arm("white");self.notice=self.roomWall.status
        }
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
            guard self.interactionReady,!self.recoveryBusy else {
                _=self.fistMenu.update(closed:nil,time:sample?.time ?? ProcessInfo.processInfo.systemUptime)
                self.palmRecall=SpatialPalmRecall();self.dualScale=SpatialDualPinchScale();self.dualScaleTarget=nil
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                self.hands.showProgress(0);return
            }
            let closed=sample?.closedFist == true
            if self.fistMenu.update(closed:sample.map{$0.closedFist && !self.panel.isDragging && !self.desktop.isDragging},time:sample?.time ?? ProcessInfo.processInfo.systemUptime) {
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                self.dualScale=SpatialDualPinchScale();self.palmRecall=SpatialPalmRecall()
                self.panel.openEffectsRadial(tracking:true);self.hands.showProgress(0);return
            }
            if closed {
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                self.hands.showProgress(0);return
            }
            if self.liveWall.armed && !self.panel.contains(sample?.point ?? CGPoint(x:-1,y:-1)) {
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                self.hands.showProgress(self.liveWall.hand(sample));return
            }
            if self.roomWall.armed && !self.panel.contains(sample?.point ?? CGPoint(x:-1,y:-1)) {
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                self.hands.showProgress(self.roomWall.hand(sample));return
            }
            if self.spatial.recovering {
                self.spatial.hand(nil)
                if self.spatial.restoredDesktop == nil,self.desktop.hand(sample) { self.hands.showProgress(self.desktop.progress) }
                else { self.hands.showProgress(0) }
                self.panel.hand(self.spatial.restoredPanel == nil ? sample : nil)
                return
            }
            let factor=self.dualScale.update(points:sample?.dualPinch,time:sample?.time ?? ProcessInfo.processInfo.systemUptime)
            if self.dualScale.active {
                if self.dualScaleTarget==nil,let points=sample?.dualPinch,points.count==2 {
                    self.dualScaleTarget=self.scaleTarget(at:CGPoint(x:(points[0].x+points[1].x)/2,y:(points[0].y+points[1].y)/2))
                }
                self.panel.hand(nil);_ = self.desktop.hand(nil);self.spatial.hand(nil)
                if let factor,let target=self.dualScaleTarget { self.resize(target,factor:factor) }
                self.hands.showProgress(0);self.handStatus="Duas pinças: afaste para aumentar, aproxime para diminuir.";return
            }
            self.dualScaleTarget=nil
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
            if self.panel.visible,self.panel.immersive,
               self.panel.isDragging || sample.map({self.panel.contains($0.point)}) == true {
                self.panel.hand(sample);self.hands.showProgress(self.panel.dwellProgress);return
            }
            if self.desktop.hand(sample) { self.hands.showProgress(self.desktop.progress);return }
            if self.panel.visible && !self.panel.immersive { self.panel.hand(sample);self.hands.showProgress(self.panel.dwellProgress) }
            else { self.panel.hand(nil);self.spatial.hand(sample);self.hands.showProgress(self.spatial.dwellProgress) }
        }
        hands.onQuality = { [weak self] in self?.handStatus=$0 }
        spatial.attach()
        spatial.onWindowPinch={ [weak self] gesture in
            guard let self,self.interactionReady else { return false }
            if gesture.state == .began {
                let point=gesture.location(in:self.view)
                self.touchScaleTarget=self.desktop.contains(point) ? "desktop" : self.panel.contains(point) ? "panel" : nil
            }
            guard let target=self.touchScaleTarget else { return false }
            if gesture.state == .changed { self.resize(target,factor:Float(gesture.scale));gesture.scale=1 }
            if gesture.state == .ended || gesture.state == .cancelled { self.touchScaleTarget=nil }
            return true
        }
        spatial.onAttackRequest = { [weak self] in self?.requestWallAttack() }
        spatial.onImpact = { [weak self] point in self?.showWallImpact(point) }
        view.session.delegate = self
        view.session.delegateQueue = .main
        coaching.session=view.session;coaching.goal = .tracking;coaching.activatesAutomatically=false;coaching.delegate=self
        coaching.autoresizingMask=[.flexibleWidth,.flexibleHeight];coaching.frame=view.bounds;view.insertSubview(coaching,at:0)
        view.delegate = performance
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.automaticallyUpdatesLighting = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false; view.isPlaying=false
        light.type = .ambient; light.intensity = stableLight
        let node = SCNNode(); node.light = light
        view.scene.rootNode.addChildNode(node)
        UIDevice.current.isBatteryMonitoringEnabled=true
        let tap = UITapGestureRecognizer(target:self, action:#selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        let ticker=WallFrameTicker();ticker.owner=self
        let link=CADisplayLink(target:ticker,selector:#selector(WallFrameTicker.tick(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
        link.isPaused=true;link.add(to:.main,forMode:.common);frameLink=link
    }

    func start() async {
        guard !started, !stopped else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "Este modo precisa de ARKit no aparelho. O simulador não reproduz o rastreamento."; fatal = true; return
        }
        let permission = await AVCaptureDevice.requestAccess(for:.video)
        guard !stopped else { return }
        guard permission else { status = "Permita a câmera nos Ajustes para pintar em AR."; fatal = true; return }
        let service=mapLocation
        locationTask=Task { [weak self] in
            guard (try? await service.currentCoordinate()) != nil,let point=service.latestLocation,
                  let self,!self.stopped,!Task.isCancelled else { return }
            let hint=SpatialMapLocation(latitude:point.coordinate.latitude,longitude:point.coordinate.longitude,accuracy:point.horizontalAccuracy,timestamp:point.timestamp)
            if hint.valid { self.spatial.locationHint=hint }
            self.refreshSavedMaps()
        }
        do { initialMap = try await spatial.loadMap() }
        catch {
            status="Não consegui ler o mapa salvo. Ele foi preservado. Escolha outro mapa ou inicie um novo."
            localizationTimedOut=true;refreshSavedMaps()
        }
        // Decode and upload once, before scanning; no image generation or downloading
        // competes with tracking. Shared PBR textures use metric UVs and mipmaps.
        for f in WallFinish.allCases { materials[f] = WallMaterials.make(f) }
        for id in ["mossrock","fern","radio"] {
            do { _ = try SpatialAssets.load(id) }
            catch { notice = "Modelo local indisponível: \(id)." }
            await Task.yield()
        }
        let ready:Bool = await withCheckedContinuation { continuation in
            view.prepare(Array(materials.values)) { ready in continuation.resume(returning:ready) }
        }
        guard !stopped else { return }
        prepared=ready;started=true
        if foreground {
            if localizationTimedOut { spatial.suspendSavedMap();savedMapSuspended=true;initialMap=nil;localizationTimedOut=false }
            calibrateCurrentRoom()
        }
    }

    private func run(reset: Bool = false) {
        guard foreground, !stopped, !fatal else { return }
        let shouldReset=reset || pendingMapReset
        let config = SpatialCaptureProfile.configuration(scanning:scanning)
        if liveWall.capturing,ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { config.sceneReconstruction = .meshWithClassification }
        if !mapStarted || shouldReset { config.initialWorldMap=initialMap;mapStarted=true }
        // Prefer moderate camera resolution at 60 Hz rather than 4K capture + AI.
        if activeVideoFormat == nil {
        let available=ARWorldTrackingConfiguration.supportedVideoFormats
        let ultra=available.filter { $0.captureDevicePosition == .back && $0.captureDeviceType == .builtInUltraWideCamera }
        let candidates=prefersUltraWide && !ultra.isEmpty ? ultra : available.filter { $0.captureDeviceType == .builtInWideAngleCamera }
        let fast=candidates.filter { $0.framesPerSecond == 60 }
        if let format=(fast.isEmpty ? candidates : fast).min(by:{$0.imageResolution.width<$1.imageResolution.width}) {
            activeVideoFormat=format;lensLabel=format.captureDeviceType == .builtInUltraWideCamera ? "0,5×" : "1×"
        }
        if prefersUltraWide && ultra.isEmpty { notice="A câmera 0,5× não foi oferecida pelo ARKit nesta configuração. A sessão usa \(lensLabel)." }
        }
        if let activeVideoFormat { config.videoFormat=activeVideoFormat }
        view.session.run(config,options:shouldReset ? [.resetTracking,.removeExistingAnchors] : [])
        pendingMapReset=false
        videoRunning=true;view.isPlaying = true;view.rendersContinuously = true
        frameLink?.isPaused=false
        armRecoveryTimer()
    }

    private func scaleTarget(at point:CGPoint)->String? {
        if desktop.contains(point) { return "desktop" }
        if panel.contains(point) { return "panel" }
        if spatial.hasSelection { return "world" }
        if lastWindow=="desktop",desktop.visible { return "desktop" }
        return panel.visible ? "panel" : desktop.visible ? "desktop" : nil
    }
    private func resize(_ target:String,factor:Float) {
        guard factor.isFinite,factor>0 else { return }
        switch target { case "desktop":desktop.resize(factor);case "panel":panel.resize(factor);default:spatial.resizeSelected(factor) }
    }
    func selectLens(ultra: Bool) {
        guard !recoveryBusy else { return }
        if ultra && !ARWorldTrackingConfiguration.supportedVideoFormats.contains(where:{$0.captureDeviceType == .builtInUltraWideCamera && $0.captureDevicePosition == .back}) {
            notice="O iOS não disponibilizou 0,5× para esta sessão AR.";return
        }
        prefersUltraWide=ultra;activeVideoFormat=nil;spatial.stopMoving();hands.reset();spatial.requireSurfaceConfirmation();run()
    }

    func toggleScan() {
        guard started,foreground,!stopped,!recoveryBusy,!fatal else { return }
        scanTask?.cancel();scanTask=nil
        if scanning { scanning=false;run();status="Leitura desligada. Ambiente fixo.";return }
        scanning=true;run();status="Lendo superfícies por 8 segundos. Depois a leitura será desligada."
        scanTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(SpatialCaptureProfile.scanSeconds))
            guard !Task.isCancelled,let self,!self.stopped else { return }
            self.scanning=false;self.scanTask=nil;self.run()
            self.status="Leitura desligada. Use as superfícies já lidas ou escaneie novamente quando quiser."
        }
    }

    func beginRoomMatching() {
        roomSetupPresented=false;roomWall.beginMatching()
        guard roomWall.matching else { return }
        scanTask?.cancel();scanning=true;run()
        scanTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(90))
            guard !Task.isCancelled,let self,!self.stopped else { return }
            self.roomWall.cancelMatching();self.scanning=false;self.scanTask=nil;self.run()
            self.notice="Alinhamento pausado. Abra Alinhar quarto para tentar novamente."
        }
    }
    func beginHandsFreeWall(_ style:String) {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            notice="Este teste automático precisa do LiDAR e de classificação da malha.";feedback(notice);return
        }
        roomWall.cancelMatching();roomWall.cancelPaint();liveWall.arm(style);measureMode = .none
        if !liveWall.capturing { feedback(liveWall.status);return }
        scanTask?.cancel();scanning=true;run();feedback(liveWall.status)
        scanTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(8))
            guard !Task.isCancelled,let self,!self.stopped else { return }
            self.liveWall.finishCapture();self.scanning=false;self.scanTask=nil;self.run()
        }
    }
    func calibrateCurrentRoom() {
        guard started,foreground,!stopped,!recoveryBusy,!fatal else { return }
        scanTask?.cancel();endManualWallInput();liveWall.beginCalibration();scanning=true
        status=liveWall.status;run();feedback(status)
        scanTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(8))
            guard !Task.isCancelled,let self,!self.stopped else { return }
            self.liveWall.finishCapture();self.scanning=false;self.scanTask=nil;self.run()
            self.spatial.markDirty();self.status="Leitura encerrada. O único mapa atual será salvo quando o rastreamento estiver estável."
        }
    }
    private func prepareObjectPlacement() {
        guard !planes.values.contains(where:{$0.classification == .floor || $0.classification == .table}),!scanning else { return }
        toggleScan()
        feedback("Olhe para uma área livre do piso ou da mesa. Depois aponte por dois segundos para colocar o modelo.")
    }
    private func cancelLiveWallCapture() {
        portalRequested=false
        let reading=liveWall.capturing
        liveWall.cancel()
        if reading {
            scanTask?.cancel();scanTask=nil;scanning=false;run()
        }
    }
    private func endManualWallInput() {
        if roomWall.matching { cancelRoomMatching() }
        roomWall.cancelPaint();roomSetupPresented=false
    }
    func cancelRoomMatching() {
        roomWall.cancelMatching();roomWall.cancelPaint()
        scanTask?.cancel();scanTask=nil
        if scanning { scanning=false;run() }
    }

    func beginPortal() {
        portalRequested=true;beginHandsFreeWall("white")
        guard liveWall.armed else { portalRequested=false;return }
        liveWall.onSurface = { [weak self] hit,meshes in
            guard let self else { return false }
            let placed=self.portal.place(hit,meshes:meshes)
            if placed { self.portalRequested=false }
            return placed
        }
        feedback("Aponte para uma área livre da parede por dois segundos. Vou abrir um portal para um bosque.")
    }
    private func releaseUnlocalizedMap() {
        // A saved coordinate frame is never transplanted to a guessed camera pose.
        let resumePortal=portalRequested
        scanTask?.cancel();scanTask=nil;scanning=false
        panel.close(recordChange:false);desktop.close(recordChange:false);portal.clear(recordChange:false)
        roomWall.clear();liveWall.clear();spatial.suspendSavedMap()
        savedMapSuspended=true;initialMap=nil;mapStarted=false;planes.removeAll();occluders.values.forEach{$0.removeFromParentNode()};occluders.removeAll()
        poseStability.reset();tracking=false;interactionReady=false;run(reset:true)
        if resumePortal { beginPortal() } else { calibrateCurrentRoom() }
        feedback("O mapa antigo não foi reconhecido. Liberei uma sessão nova sem apagar o salvo. Diga recuperar mapa para tentar de novo; salvar mapa substitui o anterior.")
    }
    private func armRecoveryTimer() {
        guard recoveryTimer == nil,(!tracking || spatial.recovering) else { return }
        recoveryTimer=Task { [weak self] in
            try? await Task.sleep(for:self?.recoveryDelay ?? .seconds(20))
            guard !Task.isCancelled,let self,!self.stopped,(!self.tracking || self.spatial.recovering) else { return }
            if self.initialMap != nil && !self.savedMapSuspended {
                self.recoveryTimer=nil;self.releaseUnlocalizedMap();return
            }
            self.localizationTimedOut=true;self.status="A câmera precisa de mais detalhes e luz. O mapa salvo continua preservado."
            self.refreshSavedMaps()
            self.recoveryTimer=nil
        }
    }

    func retryLocalization() {
        guard started,!stopped,!recoveryBusy,!fatal else { return }
        recoveryTimer?.cancel();recoveryTimer=nil;localizationTimedOut=false
        if savedMapSuspended {
            recoveryBusy=true
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.spatial.suspendSavedMap()
                    let map=try await self.spatial.loadMap()
                    self.portal.clear(recordChange:false);self.panel.close(recordChange:false);self.desktop.close(recordChange:false)
                    self.liveWall.clear();self.roomWall.clear();self.initialMap=map;self.savedMapSuspended=false
                    self.poseStability.reset();self.run(reset:true)
                } catch { self.notice="Não consegui ler o mapa salvo; ele foi preservado." }
                self.recoveryBusy=false
                if !self.savedMapSuspended { self.calibrateCurrentRoom() }
            }
            return
        }
        status="Retomando a mesma sessão e suas âncoras. Mostre detalhes do ambiente original."
        run() // Deliberately no resetTracking or removeExistingAnchors.
    }
    func refreshSavedMaps() {
        let location=spatial.locationHint
        Task { [weak self] in
            let files=await Task.detached { SpatialArchive.savedMaps(near:location) }.value
            guard let self,!self.stopped else { return };self.savedMaps=files
        }
    }

    func setHeadset(_ value: Bool) {
        headset=value;hands.reset()
        view.isPlaying=videoRunning;view.rendersContinuously=view.isPlaying
        guard let scene=view.window?.windowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:value ? .landscapeRight : .portrait)) { [weak self] _ in
            Task { @MainActor in self?.notice="Gire o iPhone na horizontal e confira se o bloqueio de rotação está desligado." }
        }
        notice=value ? "VR Box: câmera única, duas vistas iguais. Deixe a câmera traseira livre; ajuste as lentes no visor." : "Modo de mão única."
    }

    func changeMap(restore source: URL?) {
        guard started,!recoveryBusy else { return };recoveryBusy=true;localizationTimedOut=false
        let hadDesktop=desktop.visible,savedScale=desktop.snapshot()?.scale ?? 0.7
        scanTask?.cancel();scanTask=nil;scanning=false
        recoveryTimer?.cancel();recoveryTimer=nil
        spatial.stopMoving();frameLink?.isPaused=true;videoRunning=false;view.session.pause();view.isPlaying=false;view.rendersContinuously=false;tracking=false;interactionReady=false;poseStability.reset();_ = gate.update(normal:false,at:0);setVisible(false);desktop.setTracking(false)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.spatial.prepareMapChange(restore:source)
                guard !self.stopped else { self.spatial.finishMapChange();return }
                self.panel.close(recordChange:false);self.desktop.close(recordChange:false);self.roomWall.clear();self.liveWall.clear();self.portal.clear(recordChange:false);self.clear(silent:true)
                self.spatial.resetLiveScene(newWorld:source == nil)
                self.occluders.values.forEach { $0.removeFromParentNode() };self.occluders.removeAll();self.planes.removeAll();self.meshUpdated.removeAll()
                self.initialMap=source == nil ? nil : try await self.spatial.loadMap()
                self.desktopResume.prepare(wasOpen:hadDesktop,savedWindow:self.spatial.restoredDesktop != nil)
                self.desktopResumeScale=savedScale
                self.mapStarted=false;self.pendingMapReset=true;self.fatal=false;self.recoveryBusy=false;self.spatial.finishMapChange()
                self.status=source == nil ? "Novo mapeamento. Mostre piso, cantos e detalhes das paredes." : "Reconhecendo o mapa salvo. Volte ao ambiente onde ele foi gravado."
                if !self.stopped { self.run(reset:true) }
            } catch {
                self.recoveryBusy=false;self.spatial.finishMapChange();self.localizationTimedOut=true
                self.status="Não consegui restaurar esse mapa. \(error.localizedDescription)"
            }
            self.refreshSavedMaps()
        }
    }

    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        localizationTimedOut=true;coachingOverlayView.setActive(false,animated:true)
        refreshSavedMaps()
    }
    #if DEBUG
    func previewRecovery(tracking: Bool,anchorsPending: Bool,delay: Duration) {
        self.tracking=tracking;recoveryDelay=delay
        if anchorsPending { spatial.restoredPanel=SpatialPanelRecord(anchor:UUID(),module:"dashboard",scale:0.5) }
        armRecoveryTimer()
    }
    #endif

    func setForeground(_ active: Bool) {
        foreground = active
        if active && started && !recoveryBusy {
            if liveWall.capturing { if portalRequested { beginPortal() } else { calibrateCurrentRoom() } }
            else { run() }
        }
        else if !active {
            frameLink?.isPaused=true
            scanTask?.cancel();scanTask=nil;scanning=false
            recoveryTimer?.cancel();recoveryTimer=nil
            spatial.stopMoving()
            spatial.saveMap(force:true)
            spatial.requireSurfaceConfirmation()
            desktop.setTracking(false)
            videoRunning=false;view.session.pause(); view.isPlaying = false;view.rendersContinuously=false
            tracking = false;interactionReady=false;poseStability.reset(); _ = gate.update(normal:false, at:0); setVisible(false)
        }
    }

    func stop() {
        locationTask?.cancel();locationTask=nil
        frameLink?.invalidate();frameLink=nil
        if headset { setHeadset(false) }
        scanTask?.cancel();scanTask=nil;scanning=false
        recoveryTimer?.cancel();recoveryTimer=nil
        spatial.saveMap(force:true)
        stopped = true
        hands.reset()
        videoRunning=false;view.session.pause(); view.isPlaying = false;view.rendersContinuously=false
        view.session.delegate = nil; view.delegate = nil
        onFeedback = nil
        // The asynchronous world-map snapshot still needs these anchors.
        panel.close(recordChange:false,preserveAnchor:true)
        desktop.close(recordChange:false,preserveAnchor:true)
        roomWall.clear(preserveAnchor:true)
        liveWall.clear()
        portal.clear(recordChange:false,preserveAnchor:true)
        spatial.stop()
        materials.removeAll(); occluders.removeAll(); planes.removeAll()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point=gesture.location(in:view)
        tap(at:point)
    }
    func tap(at point:CGPoint) {
        guard interactionReady else { return }
        if panel.visible,panel.immersive,panel.contains(point) { _=panel.hit(point);return }
        if liveWall.tap(point) { return }
        if roomWall.tap(point) { return }
        if desktop.tap(point) { return }
        if panel.visible && !panel.immersive { _=panel.hit(point);return }
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
        case .portal: beginPortal()
        case .closePortal: portalRequested=false;liveWall.onSurface=nil;portal.clear();feedback("Portal fechado.")
        case .calibrate: calibrateCurrentRoom()
        case .effects: panel.openEffectsRadial(tracking:interactionReady)
        case .roomSetup:
            cancelLiveWallCapture();roomWall.cancelPaint()
            if roomWall.prepare() { roomWall.resetSource();roomSetupPresented=true }
            else { notice=roomWall.status;feedback(notice) }
        case .roomWall(let style):
            if roomWall.aligned { roomWall.arm(style);notice=roomWall.status }
            else { beginHandsFreeWall(style) }
        case .roomClear: cancelLiveWallCapture();roomWall.clearPaint();liveWall.clear();notice="Pintura removida."
        case .open: break
        case .headset(let enabled): setHeadset(enabled)
        case .recover: retryLocalization();feedback(status)
        case .keyboard(let show):
            if show && !desktop.visible { desktop.open(tracking:tracking) }
            desktop.showKeyboard(show);feedback(show ? "Teclado projetado na janela do computador." : "Teclado recolhido.")
        case .select:
            if select() { feedback("Marque os cantos da parede e as áreas que devem ficar livres.") }
            else { feedback(status) }
        case .finish(let value):
            if roomWall.aligned,value == .white,!selected { roomWall.arm("white");notice=roomWall.status;return }
            if value == .white,!selected { beginHandsFreeWall("white");return }
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
        case .panel(let module): panel.open(module,tracking:interactionReady && spatial.restoredPanel == nil)
        case .navigate(let text): panel.interpret(text)
        case .measure: beginOutline()
        case .point: addPoint()
        case .opening: beginOpening()
        case .approve: confirm()
        case .theme(let theme): measureMode = .none;endManualWallInput();cancelLiveWallCapture();spatial.setTheme(theme);prepareObjectPlacement()
        case .interact: spatial.interact()
        case .removeObject: spatial.removeSelected()
        case .model(let id): measureMode = .none;endManualWallInput();cancelLiveWallCapture();spatial.setModel(id);prepareObjectPlacement()
        case .resizeObject(let factor): spatial.resizeSelected(factor)
        case .moveObject(let x,let z): spatial.moveSelected(x:x,z:z)
        case .saveMap:
            if savedMapSuspended { spatial.approveLiveMapReplacement();savedMapSuspended=false;feedback("Vou salvar este ambiente como o mapa atual.") }
            spatial.saveMap()
        case .room(let name): spatial.chooseRoom(name)
        case .desktop: desktop.open(tracking:interactionReady && spatial.restoredDesktop == nil)
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
        roomWall.setTracking(visible)
        liveWall.setTracking(visible)
        if !visible { hands.showProgress(0) }
    }

    fileprivate func pollFrame() {
        guard foreground,!stopped,!fatal,let frame=view.session.currentFrame else { return }
        receive(frame)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) { receive(frame) }
    private func receive(_ frame: ARFrame) {
        guard foreground, !stopped,!recoveryBusy,!fatal,frameInput.accept(frame.timestamp) else { return }
        // Reading existing anchor poses is distinct from scanning surfaces or
        // rebuilding meshes. This also recovers callbacks hidden by a renderer.
        receiveTrackedAnchors(frame.anchors)
        let normal: Bool,transient: Bool
        switch frame.camera.trackingState {
        case .normal: normal=true;transient=false
        case .limited(.insufficientFeatures),.limited(.excessiveMotion): normal=false;transient=true
        default: normal=false;transient=false
        }
        let pose=frame.camera.transform
        let stablePose=poseStability.update(position:SIMD3(pose.columns.3.x,pose.columns.3.y,pose.columns.3.z),forward:SIMD3(pose.columns.2.x,pose.columns.2.y,pose.columns.2.z),time:frame.timestamp)
        let good = gate.update(normal:normal && stablePose,at:frame.timestamp,transient:transient && stablePose)
        interactionReady=good && normal && stablePose
        let readiness=spatial.readiness(cameraStable:good),worldReady=readiness.localized
        if desktopResume.consume(cameraStable:interactionReady,savedWindowPending:spatial.restoredDesktop != nil) {
            desktop.open(tracking:true);desktop.resize(desktopResumeScale/0.7)
            notice="Esse mapa antigo não tinha a janela do PC. Ela foi reaberta à sua frente."
        }
        if coaching.isActive == good { coaching.setActive(!good,animated:true) }
        if good && !spatial.recovering { recoveryTimer?.cancel();recoveryTimer=nil;localizationTimedOut=false }
        // No periodic world-map snapshots or surface updates in the hand mode.
        if scanning { spatial.persistenceTick(frame) }
        spatial.setVisible(good && !comparing)
        if good && normal && !comparing {
            if scanning { spatial.validateSupports(frame) }
            else { spatial.reuseLocalizedSupports() }
        }
        if good && !comparing { spatial.stepSimulation(frame.timestamp) }
        panel.setTracking(readiness.panelReady)
        desktop.setTracking(readiness.desktopReady)
        roomWall.setTracking(good)
        liveWall.setTracking(good)
        portal.frame(frame,stable:interactionReady)
        // Vision's 2D skeleton does not need a mapped room or an active module.
        // Spatial actions remain gated in onSample above, separately from drawing.
        if headset { onHeadsetFrame?(frame) }
        hands.update(frame,view:view,enabled:!webWindowVisible && !fatal && !roomWall.matching && !roomSetupPresented)
        if tracking != worldReady {
            if !good { spatial.requireSurfaceConfirmation() }
            tracking = worldReady;painted?.isHidden = !worldReady || comparing
            if !worldReady { armRecoveryTimer() }
            status = worldReady ? (selected ? "Parede fixada. Pode mudar o material por voz." : scanning ? "Lendo novas superfícies." : "Mapa localizado e referências recuperadas.") : "Recuperando as referências do mapa. Mostre o ambiente salvo."
        }
        if good,spatial.recovering {
            let text="Câmera estável · recuperando \(spatial.pendingReferenceCount) referências salvas."
            if status != text { status=text };armRecoveryTimer()
        }
        if good,spatial.objectCount>0,!spatial.supportsConfirmed { status=spatial.persistenceStatus }
        if scanning && approved && good && frame.timestamp-lastDepthUpdate>0.5 { updateDepth(frame) }
        cameraFrames += 1
        if frame.timestamp-lastMetric >= 1 {
            let fps = performance.sample()
            if headset {
                if normal && stablePose { headsetStatus=spatial.recovering ? "Câmera ativa · mostre o cômodo salvo" : "AR · câmera ativa" }
                else if normal { headsetStatus="Câmera ativa · estabilizando movimento" }
                else {
                    switch frame.camera.trackingState {
                    case .limited(.insufficientFeatures):headsetStatus="Aponte para cantos com boa luz"
                    case .limited(.excessiveMotion):headsetStatus="Mova a cabeça mais devagar"
                    case .limited(.relocalizing):headsetStatus="Câmera ativa · reconhecendo cômodo"
                    default:headsetStatus="Câmera ativa · iniciando rastreamento"
                    }
                }
                NSLog("[SpatialVR] normal=%d stable=%d recovering=%d renderedFPS=%d",normal ? 1 : 0,stablePose ? 1 : 0,spatial.recovering ? 1 : 0,fps)
            }
            if scanning { spatial.recordPerformance(fps:fps,frame:frame,handLatencyMS:hands.latencyMS,handFound:hands.hasHand,handDepth:hands.hasDepth) }
            let mode=scanning ? "leitura temporária" : "ambiente fixo"
            metrics = fps > 0 ? "\(fps) FPS · \(mode)" : mode
            lastMetric = frame.timestamp; cameraFrames = 0
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical {
                fatal = true;frameLink?.isPaused=true;interactionReady=false;tracking=false; setVisible(false); videoRunning=false;view.session.pause(); view.isPlaying = false;view.rendersContinuously=false
                status = "iPhone quente. AR pausado; feche e deixe o aparelho esfriar."; return
            }
            spatial.setThermal(thermal)
            view.preferredFramesPerSecond = thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
            frameLink?.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:Float(view.preferredFramesPerSecond),preferred:Float(view.preferredFramesPerSecond))
            if thermal == .serious { notice = "iPhone aquecendo: renderização limitada a 30 FPS." }
            if let estimate = frame.lightEstimate {
                let target = CGFloat(min(600,max(120,estimate.ambientIntensity * 0.35)))
                stableLight += (target-stableLight)*0.12; light.intensity = stableLight
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { update(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { update(anchors) }
    func receiveTrackedAnchors(_ anchors:[ARAnchor]) { update(anchors) }
    private func update(_ anchors: [ARAnchor]) {
        guard !stopped else { return }
        for anchor in anchors {
            if anchor.identifier == worldAnchor?.identifier { worldAnchor=anchor; painted?.simdTransform = anchor.transform }
            if let plane = anchor as? ARPlaneAnchor {
                if scanning || planes[plane.identifier] == nil {
                    planes[plane.identifier]=plane;spatial.update(plane)
                    if scanning && approved && (plane.classification == .door || plane.classification == .window) { refreshAutomaticOpenings() }
                }
                continue
            }
            if let mesh=anchor as? ARMeshAnchor { liveWall.remember(mesh);continue }
            panel.update(anchor)
            desktop.update(anchor)
            liveWall.update(anchor)
            portal.update(anchor)
            if let saved=spatial.restoredPortal,saved.anchor==anchor.identifier {
                portal.restore(saved,anchor:anchor);spatial.restoredPortal=nil
            }
            roomWall.update(anchor)
            if let saved=spatial.restoredScannedRoom,saved.anchor==anchor.identifier {
                if !roomWall.restore(saved,anchor:anchor) { notice=roomWall.status }
                spatial.restoredScannedRoom=nil
            }
            if let saved=spatial.restoredDesktop,saved.anchor==anchor.identifier {
                desktop.restore(saved,anchor:anchor);spatial.restoredDesktop=nil
            }
            if let saved=spatial.restoredPanel,saved.anchor==anchor.identifier {
                panel.restore(saved,anchor:anchor);spatial.restoredPanel=nil
            }
            spatial.update(anchor)
        }
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if !scanning && anchor is ARPlaneAnchor { continue }
            spatial.remove(anchor)
            planes.removeValue(forKey:anchor.identifier)
            occluders.removeValue(forKey:anchor.identifier)?.removeFromParentNode()
            meshUpdated.removeValue(forKey:anchor.identifier)
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        view.isPlaying=false;view.rendersContinuously=false
        interactionReady=false;poseStability.reset()
        spatial.requireSurfaceConfirmation()
        tracking = false; _ = gate.update(normal:false,at:0); setVisible(false)
        status = "AR interrompido. A pintura reaparece após recuperar a posição."
    }
    func sessionInterruptionEnded(_ session: ARSession) { if foreground { run() } }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func session(_ session: ARSession,cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: break // Only the stable frame gate ends recovery.
        case .limited(.insufficientFeatures),.limited(.excessiveMotion):
            // The frame gate tolerates a short hand occlusion, without resetting Vision.
            if !tracking { armRecoveryTimer() }
        default:
            interactionReady=false;poseStability.reset()
            spatial.requireSurfaceConfirmation()
            tracking=false;_ = gate.update(normal:false,at:0);setVisible(false)
            status="Relocalizando. Volte ao ambiente anterior e mostre o piso e detalhes das paredes."
            armRecoveryTimer()
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        frameLink?.isPaused=true;tracking=false
        view.isPlaying=false;view.rendersContinuously=false
        interactionReady=false
        fatal = true; setVisible(false); status = "AR indisponível: \(error.localizedDescription). Feche e reabra este modo."
    }

    private func updateOccluder(_ anchor: ARMeshAnchor) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval=hands.hasHand && tracking ? 1.5 : 0.5
        guard now-(meshUpdated[anchor.identifier] ?? 0) > interval else { return }
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

    nonisolated static func occlusionGeometry(_ mesh: ARMeshGeometry) -> SCNGeometry? {
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
@MainActor private final class WallFrameTicker:NSObject {
    weak var owner:WallARController?
    @objc func tick(_ link:CADisplayLink) { owner?.pollFrame() }
}

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

@MainActor private struct SpatialRecoveryControls:View {
    @ObservedObject var controller:WallARController
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Ambiente atual · leitura de 8 segundos",systemImage:"viewfinder")
            Text(controller.status).font(.caption)
            Text("Olhe devagar para piso e paredes. Também pode dizer calibrar ambiente, sem tocar no iPhone.").font(.caption)
            HStack {
                Button("Repetir leitura de 8 s") { controller.apply(.calibrate) }
                Button("Recuperar posição atual") { controller.retryLocalization() }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
    }
}

struct WallCameraView: UIViewRepresentable {
    let controller: WallARController
    let headset:Bool
    func makeUIView(context: Context) -> SpatialHeadsetSurface {
        let view=SpatialHeadsetSurface(controller:controller)
        view.configure(headset:headset)
        return view
    }
    func updateUIView(_ view: SpatialHeadsetSurface, context: Context) { view.configure(headset:headset) }
}

@MainActor struct WallARStudio: View {
    @ObservedObject var model: RemoteAssistant
    @StateObject private var controller = WallARController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var help = false
    @State private var objectsTab = false
    @AppStorage("jarvis.ar.toolsExpanded.v31") private var toolsExpanded = false
    @State private var immersive=false
    @State private var panelVisible = false
    @State private var webModule: SpatialModule?
    @State private var panelStatus = ""
    @State private var menuSheet: SpatialSheet?
    @State private var search = ""
    @State private var confirmAction: PhoneAction?
    var body: some View {
        ZStack {
            WallCameraView(controller:controller,headset:controller.headset).frame(maxWidth:.infinity,maxHeight:.infinity).ignoresSafeArea(edges:controller.headset || immersive ? .all : .bottom).allowsHitTesting(webModule == nil && !controller.recoveryBusy)
            if !controller.headset && !immersive && !panelVisible && (!controller.selected || controller.measureMode != .none) {
                Image(systemName:"plus").font(.title.weight(.ultraLight)).foregroundStyle(.white)
                    .shadow(color:.black,radius:2).allowsHitTesting(false)
            }
            if let webModule {
                SpatialWebWindow(module:webModule) { self.webModule=nil;controller.panel.open(.dashboard,tracking:controller.tracking) }.id(webModule.rawValue)
            } else if !controller.headset && !immersive {
            VStack(spacing:10) {
                HStack {
                    Button { model.studioMode=nil } label: { Image(systemName:"xmark") }.accessibilityLabel("Fechar Espaço AR")
                    Label(controller.tracking ? "MAPA LOCALIZADO" : controller.spatial.recovering ? "RECUPERANDO MAPA" : "MAPEANDO",systemImage:controller.tracking ? "viewfinder" : "viewfinder.circle")
                    Spacer()
                    Button { controller.panel.open(.dashboard,tracking:controller.tracking) } label: { Image(systemName:"square.grid.2x2") }
                    Button { controller.desktop.open(tracking:controller.tracking) } label: { Image(systemName:"desktopcomputer") }.accessibilityLabel("Abrir tela do PC em AR")
                    Button { controller.panel.reposition() } label: { Image(systemName:"scope") }.accessibilityLabel("Trazer painel para frente")
                    Menu(controller.lensLabel) {
                        Button("0,5× · ultra-angular") { controller.selectLens(ultra:true) }
                        Button("1× · principal") { controller.selectLens(ultra:false) }
                    }
                    Button { controller.localizationTimedOut.toggle();controller.refreshSavedMaps() } label: { Image(systemName:"map") }.accessibilityLabel("Recuperar mapa")
                    Button { controller.setHeadset(true) } label: { Image(systemName:"visionpro") }.accessibilityLabel("Ativar VR Box horizontal")
                    Button { controller.panel.open(.dashboard,tracking:controller.tracking);controller.panel.cleanInterface() } label: { Image(systemName:"eye.slash") }.accessibilityLabel("Modo limpo com menu projetado").disabled(!controller.tracking)
                }.font(.caption.monospaced()).padding(12).background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:14))
                HStack {
                    Text(controller.metrics).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    if let location=controller.spatial.locationHint {
                        Text("GPS ±\(Int(location.accuracy)) m").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(controller.scanning ? "Parar leitura" : "Escanear 8 s") { controller.toggleScan() }
                        .font(.caption).buttonStyle(.bordered).controlSize(.small)
                }
                Text(controller.handStatus).font(.caption2).foregroundStyle(.cyan).lineLimit(1)
                if controller.localizationTimedOut || controller.recoveryBusy {
                    SpatialRecoveryControls(controller:controller)
                }
                Spacer()
                SpatialDesktopControls(desktop:controller.desktop)
                if panelVisible {
                    VStack(alignment:.leading,spacing:6) {
                        Text(panelStatus).font(.caption).lineLimit(3)
                        Text(controller.handStatus).font(.caption2).foregroundStyle(.cyan)
                        Text("Indicador por 2 s clica. Só a pinça altera tamanho e posição. Palma aberta não redimensiona; fora do painel por 1 s traz uma janela desenquadrada.").font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Todos os módulos",systemImage:"list.bullet") { search="";menuSheet = .directory }
                            Button("Menor",systemImage:"minus.magnifyingglass") { controller.panel.resize(0.82) }
                            Button("Centralizar",systemImage:"scope") { controller.panel.reposition() }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:14))
                } else if toolsExpanded {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:8) {
                    Picker("Ferramenta",selection:$objectsTab) {
                        Text("Medir e pintar").tag(false)
                        Text("Cenários 3D").tag(true)
                    }.pickerStyle(.segmented)
                    Button { toolsExpanded=false } label: {
                        Image(systemName:"xmark").frame(minWidth:36,minHeight:36)
                    }.buttonStyle(.plain).accessibilityLabel("Recolher ferramentas AR")
                    }
                    if objectsTab {
                        SpatialControls(world:controller.spatial)
                    } else {
                    Text(controller.status).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                    HStack {
                        Button("Alinhar captura",systemImage:"scope") { controller.apply(.roomSetup) }
                        Button("Parede branca") { controller.apply(.roomWall("white")) }
                        Button("Tijolos") { controller.apply(.roomWall("brick")) }
                    }.buttonStyle(.bordered).controlSize(.small)
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
                } else {
                    HStack {
                        Button { toolsExpanded=true } label: {
                            Label("Ferramentas",systemImage:"slider.horizontal.3").font(.subheadline.weight(.medium)).padding(12)
                        }.buttonStyle(.plain).background(.black.opacity(0.75),in:Capsule())
                            .accessibilityLabel("Abrir ferramentas de cenários 3D, medir e pintar")
                        Spacer()
                    }
                }
            }.padding(12)
            }
            if controller.headset && !immersive {
                VStack {
                    HStack(spacing:24) {
                        ForEach(0..<2,id:\.self) { _ in
                            HStack {
                                Button("Sair VR") { controller.setHeadset(false) }.buttonStyle(.bordered)
                                Spacer()
                                Text(controller.headsetStatus).font(.caption2)
                            }.padding(12).frame(maxWidth:.infinity)
                        }
                    }
                    Spacer()
                }
            }
        }.background(.black).foregroundStyle(.white)
            .toolbar(controller.headset || immersive ? .hidden : .visible,for:.navigationBar)
            .statusBarHidden(controller.headset || immersive)
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
                        objectsTab=false;if controller.panel.immersive { controller.panel.cleanInterface() } else { controller.panel.close() };controller.apply(command)
                    case .systemAction(let action):
                        if [.wifiOff,.bluetoothOff,.cellularOff,.lock].contains(action) { confirmAction=action }
                        else { runPhoneAction(action) }
                    case .activateSpotify: model.showSpotify()
                    case .model(let id): objectsTab=true;controller.apply(.model(id));if controller.panel.immersive { controller.panel.cleanInterface() } else { controller.panel.close() }
                    case .scene(let theme): objectsTab=true;controller.apply(.theme(theme));if controller.panel.immersive { controller.panel.cleanInterface() } else { controller.panel.close() }
                    case .studio(let mode): controller.panel.close();model.openStudio(mode)
                    case .command(let text): Task { await model.runSpatialCommand(text) }
                    default: break
                    }
                }
                await controller.start()
                consume()
            }
            .sheet(isPresented:$controller.roomSetupPresented) {
                ScannedRoomSetup(room:controller.roomWall) { controller.beginRoomMatching() }
            }
            .overlay(alignment:.bottom) {
                VStack {
                    if !controller.headset {
                        LiveWallPrompt(wall:controller.liveWall)
                        ScannedRoomPrompt(room:controller.roomWall) { controller.cancelRoomMatching() }
                    }
                }.padding(.bottom,controller.headset ? 12 : 22)
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
            .onReceive(controller.panel.$visible) { panelVisible=$0;controller.spatial.panelBlocking=($0 && !immersive) || overlayVisible }
            .onReceive(controller.panel.$immersive) {
                immersive=$0;controller.hands.setSkeletonVisible(!$0)
                controller.spatial.panelBlocking=(panelVisible && !$0) || overlayVisible
            }
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
        controller.spatial.panelBlocking=overlayVisible || (panelVisible && !immersive)
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
