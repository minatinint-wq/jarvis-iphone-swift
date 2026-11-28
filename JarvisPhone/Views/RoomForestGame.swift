import ARKit
import SceneKit
import AVFoundation

/// Local hands-free game; the captured mesh remains the collision/occlusion surface.
@MainActor final class RoomForestGame {
    private let view:ARSCNView
    private weak var room:ScannedRoomWall?
    private(set) var enabled=false
    private var paused=false,finished=false,tracking=false
    private var root:SCNNode?
    private var targets:[String:SCNNode]=[:]
    private var spots:[SIMD3<Float>]=[]
    private var guardianSites:[(scale:Float,spots:[SIMD3<Float>])]=[]
    private var score=0,collected=0,bossHealth=0
    private var remaining:Double=90,lastTime:Double?,lastSpawn = -Double.infinity
    private var trigger=SpatialPortalTrigger(),pinched=false
    private var label:SCNText?
    private var sound:AVAudioPlayer?
    var onFeedback:((String)->Void)?
    init(view:ARSCNView) { self.view=view }
    static func guardian(scale:Float)throws->SCNNode {
        let wrapper=SCNNode();wrapper.name="game-guardian";wrapper.simdScale=SIMD3(repeating:scale)
        let model=try SpatialAssets.load("animated_treant")
        // Hit surfaces carry the game ID; skeleton and joint names remain intact
        // so the real reaction/death clips can still find their bones.
        model.enumerateChildNodes { node,_ in
            if node.geometry != nil { node.categoryBitMask |= 64;node.name="game-guardian" }
        }
        wrapper.addChildNode(model);return wrapper
    }
    func start(room:ScannedRoomWall) {
        guard let pose=room.pose else { return };stop();self.room=room;enabled=true;remaining=90
        let root=SCNNode();root.name="RoomForest-game";root.simdTransform=pose;self.root=root;view.scene.rootNode.addChildNode(root)
        spots=room.gameSpots()
        guardianSites=[(1,room.gameSpots(radius:1.1)),(0.6,room.gameSpots(radius:0.65)),(0.33,room.gameSpots(radius:0.36))]
        makeScoreboard();refreshLabel()
        if let url=Bundle.main.url(forResource:"RoomForest_pickup",withExtension:"wav") { sound=try? AVAudioPlayer(contentsOf:url);sound?.volume=0.35;sound?.prepareToPlay() }
        onFeedback?("Caçada da Floresta. Acerte seis cristais com o gesto de arma para chamar o guardião. Pode pegar cristais próximos com a pinça. Diga pausar jogo ou sair do jogo quando quiser.")
    }
    func stop() {
        root?.removeFromParentNode();root=nil;targets=[:];enabled=false;paused=false;finished=false;tracking=false;score=0;collected=0;bossHealth=0;lastTime=nil;lastSpawn = -Double.infinity;trigger.reset();pinched=false;sound?.stop();sound=nil
    }
    func pause(_ value:Bool) { paused=value;trigger.reset();lastTime=nil;refreshLabel() }
    func showScore() { makeScoreboard();refreshLabel();onFeedback?("Você tem \(score) pontos e \(Int(remaining)) segundos restantes.") }
    private func makeScoreboard() {
        guard let root,let frame=view.session.currentFrame else { return }
        root.childNode(withName:"game-scoreboard",recursively:false)?.removeFromParentNode()
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        guard let pose=SpatialPanelGeometry.upright(camera:simd_inverse(frame.camera.viewMatrix(for:orientation)),distance:0.8) else { return }
        let board=SCNNode();board.name="game-scoreboard";board.simdTransform=simd_inverse(root.simdTransform)*pose
        board.simdPosition.y+=0.22
        let plate=SCNNode(geometry:SCNPlane(width:0.42,height:0.075));let mat=SCNMaterial();mat.lightingModel = .constant;mat.diffuse.contents=UIColor(white:0.01,alpha:0.82);mat.isDoubleSided=true;plate.geometry?.materials=[mat];board.addChildNode(plate)
        let text=SCNText(string:"",extrusionDepth:0);text.font=UIFont.monospacedDigitSystemFont(ofSize:18,weight:.semibold);text.firstMaterial?.lightingModel = .constant;text.firstMaterial?.diffuse.contents=UIColor.cyan
        let node=SCNNode(geometry:text);node.scale=SCNVector3(0.00125,0.00125,0.00125);node.position=SCNVector3(-0.19,-0.012,0.003);board.addChildNode(node);root.addChildNode(board);label=text
    }
    private func refreshLabel() {
        label?.string=finished ? "\(score) PT · \(bossHealth==0 && collected>=6 ? "VITÓRIA" : "TEMPO")" : paused ? "PAUSADO · \(score) PT" : "\(score) PT · \(Int(remaining))s · \(collected<6 ? "\(collected)/6" : "GUARDIÃO \(bossHealth)/3")"
    }
    func frame(time:Double,stable:Bool) {
        guard enabled else { return };tracking=stable;root?.isHidden = !stable
        if let pose=room?.pose { root?.simdTransform=pose }
        guard stable,!paused,!finished else { lastTime=nil;trigger.reset();return }
        let dt=lastTime.map{max(0,min(0.1,time-$0))} ?? 0;lastTime=time
        let before=Int(remaining);remaining=max(0,remaining-dt);if Int(remaining) != before { refreshLabel() }
        if remaining==0 { finished=true;targets.values.forEach{$0.removeFromParentNode()};targets=[:];refreshLabel();onFeedback?("Tempo encerrado. Você fez \(score) pontos. Diga jogar novamente para recomeçar.");return }
        if time-lastSpawn>1.2 { spawn();lastSpawn=time }
    }
    private func candidate(sites:[SIMD3<Float>]?=nil)->SIMD3<Float>? {
        guard let root,let frame=view.session.currentFrame else { return nil }
        let eye=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        for p in (sites ?? spots).shuffled() {
            guard targets.values.allSatisfy({simd_distance($0.simdPosition,p)>0.65}) else { continue }
            let q=root.simdTransform*SIMD4(p+SIMD3(0,0.65,0),1),world=SIMD3(q.x,q.y,q.z),distance=simd_distance(eye,world)
            guard distance>0.75,distance<3.4 else { continue }
            let screen=view.projectPoint(SCNVector3(world));let point=CGPoint(x:CGFloat(screen.x),y:CGFloat(screen.y))
            guard screen.z>0,screen.z<1,view.bounds.insetBy(dx:25,dy:30).contains(point) else { continue }
            if let solid=view.hitTest(point,options:[.categoryBitMask:16,.backFaceCulling:false]).first,simd_distance(SIMD3<Float>(solid.worldCoordinates.x,solid.worldCoordinates.y,solid.worldCoordinates.z),eye)<distance-0.12 { continue }
            return p
        }
        return nil
    }
    private func spawn() {
        guard let root else { return }
        if collected>=6 {
            guard targets.isEmpty,bossHealth==0 else { return }
            // A large free area in another room must not prevent the boss from
            // appearing in the smaller, visible space where the player is.
            var placement:(point:SIMD3<Float>,scale:Float)?
            for group in guardianSites {
                if let point=candidate(sites:group.spots) { placement=(point,group.scale);break }
            }
            guard let placement,let model=try? Self.guardian(scale:placement.scale) else { return }
            let id="game-guardian";model.simdPosition=placement.point
            root.addChildNode(model);targets[id]=model;bossHealth=3;refreshLabel();onFeedback?("O guardião apareceu. Três acertos para concluir a caçada.");return
        }
        guard targets.count<3,let p=candidate() else { return }
        let id="crystal-"+UUID().uuidString,node=SCNNode();node.name=id;node.simdPosition=p+SIMD3(0,0.65,0)
        let seed=SCNNode(geometry:SCNOctahedron.make(radius:0.12)),material=SCNMaterial();material.lightingModel = .physicallyBased;material.diffuse.contents=UIColor(red:0.16,green:0.83,blue:0.70,alpha:1);material.metalness.contents=0.65;material.roughness.contents=0.18;material.emission.contents=UIColor(red:0.01,green:0.20,blue:0.11,alpha:1);seed.geometry?.materials=[material];seed.name=id;seed.categoryBitMask=65;node.addChildNode(seed)
        let ring=SCNNode(geometry:SCNTorus(ringRadius:0.16,pipeRadius:0.008));ring.eulerAngles.x = .pi/3;ring.geometry?.materials=[material];ring.name=id;ring.categoryBitMask=65;node.addChildNode(ring)
        node.runAction(.repeatForever(.rotateBy(x:0,y:.pi*2,z:0,duration:5)),forKey:"spin");root.addChildNode(node);targets[id]=node
    }
    @discardableResult func hand(_ sample:SpatialHandSample?)->Bool {
        guard enabled,tracking,!paused,!finished else { return false }
        let shot=trigger.update(gun:sample.map{$0.portalGun},thumbRaised:sample?.thumbRaised ?? false,time:sample?.time ?? ProcessInfo.processInfo.systemUptime)
        guard let sample else { pinched=false;return true }
        let pinch=sample.ratio.isFinite && sample.ratio<0.28
        defer { pinched=pinch }
        if shot { fire(sample) }
        else if pinch,!pinched,let hand=sample.worldPoint,
                let nearest=targets.first(where:{$0.key.hasPrefix("crystal") && simd_distance($0.value.simdWorldPosition,hand)<0.30}) { hit(nearest.key,points:15) }
        return true
    }
    private func fire(_ sample:SpatialHandSample) {
        guard let frame=view.session.currentFrame else { return }
        let eye=SIMD3(frame.camera.transform.columns.3.x,frame.camera.transform.columns.3.y,frame.camera.transform.columns.3.z)
        let solid=view.hitTest(sample.point,options:[.categoryBitMask:16,.backFaceCulling:false]).first
        let target=view.hitTest(sample.point,options:[.categoryBitMask:64,.backFaceCulling:false]).first
        func distance(_ hit:SCNHitTestResult)->Float { simd_distance(SIMD3<Float>(hit.worldCoordinates.x,hit.worldCoordinates.y,hit.worldCoordinates.z),eye) }
        let visible=RoomForestShot.visible(target:target.map(distance),obstacle:solid.map(distance))
        let far=view.unprojectPoint(SCNVector3(Float(sample.point.x),Float(sample.point.y),1)),direction=simd_normalize(SIMD3(far)-eye)
        let end=visible ? SIMD3(target!.worldCoordinates) : solid.map{SIMD3($0.worldCoordinates)} ?? eye+direction*3
        beam(from:sample.worldPoint ?? eye+direction*0.15,to:end)
        if visible,let id=target?.node.name { hit(id,points:10) }
    }
    private func hit(_ id:String,points:Int) {
        guard let node=targets[id] else { return };sound?.currentTime=0;sound?.play()
        if id=="game-guardian" {
            _=SpatialCreatureAudio.shared.play("animated_treant",position:node.simdWorldPosition,camera:view.session.currentFrame?.camera.transform)
            bossHealth-=1;score+=25
            _=SpatialRig.play(node,clip:bossHealth==0 ? "Die" : "Roar")
            if bossHealth==0 { node.runAction(.sequence([.wait(duration:2.5),.fadeOut(duration:0.4),.removeFromParentNode()]));finished=true;score+=100;onFeedback?("Caçada concluída. Você fez \(score) pontos.") }
        } else { score+=points;collected+=1;node.runAction(.sequence([.group([.scale(to:0.01,duration:0.2),.fadeOut(duration:0.2)]),.removeFromParentNode()]));targets.removeValue(forKey:id) }
        if collected>=6 { for (key,value) in targets where key != "game-guardian" { value.removeFromParentNode();targets.removeValue(forKey:key) } }
        refreshLabel()
    }
    private func beam(from a:SIMD3<Float>,to b:SIMD3<Float>) {
        guard let root else { return };let inverse=simd_inverse(root.simdTransform),x=inverse*SIMD4(a,1),y=inverse*SIMD4(b,1),u=SIMD3(x.x,x.y,x.z),v=SIMD3(y.x,y.y,y.z),delta=v-u,length=simd_length(delta)
        guard length>0.01 else { return }
        let ray=SCNNode(geometry:SCNCylinder(radius:0.004,height:CGFloat(length)));ray.simdPosition=(u+v)/2;ray.simdOrientation=simd_quatf(from:SIMD3(0,1,0),to:delta/length)
        let material=SCNMaterial();material.lightingModel = .constant;material.diffuse.contents=UIColor.cyan;ray.geometry?.materials=[material];root.addChildNode(ray);ray.runAction(.sequence([.fadeOut(duration:0.16),.removeFromParentNode()]))
    }
}

enum SCNOctahedron {
    static func make(radius:Float)->SCNGeometry {
        let p:[SCNVector3]=[.init(0,radius,0),.init(radius,0,0),.init(0,0,radius),.init(-radius,0,0),.init(0,0,-radius),.init(0,-radius,0)]
        let i:[Int32]=[0,2,1,0,3,2,0,4,3,0,1,4,5,1,2,5,2,3,5,3,4,5,4,1]
        return SCNGeometry(sources:[SCNGeometrySource(vertices:p),SCNGeometrySource(normals:p.map{SCNVector3(simd_normalize(SIMD3<Float>($0.x,$0.y,$0.z)))})],elements:[SCNGeometryElement(indices:i,primitiveType:.triangles)])
    }
}
