import XCTest
import SwiftUI
import AVFoundation
import SceneKit
import Metal
import CoreVideo
import CoreImage
import ARKit
@testable import JarvisPhone

final class PhoneCommandTests: XCTestCase {

    func testDoorPortalThumbTriggerRejectsLostTrackingAndDoesNotRepeat() {
        var trigger=SpatialPortalTrigger()
        for t in [0.0,0.15,0.31] { XCTAssertFalse(trigger.update(gun:true,thumbRaised:true,time:t)) }
        XCTAssertTrue(trigger.update(gun:true,thumbRaised:false,time:0.35))
        XCTAssertFalse(trigger.update(gun:true,thumbRaised:false,time:0.4))
        _=trigger.update(gun:nil,thumbRaised:false,time:0.5)
        XCTAssertFalse(trigger.update(gun:true,thumbRaised:false,time:0.6))
    }
    func testDoorPassageRequiresContinuousExitThenReturnThroughOpening() {
        var door=SpatialDoorPassage(),events:[Bool]=[];var time=0.0
        for z:Float in [1,0.7,0.4,0.1,-0.1,-0.4,-0.1,0.1,0.4] {
            if let e=door.update(position:SIMD3(0,0.55,z),time:time,width:0.8,height:2,stable:true) { events.append(e) };time+=0.1
        }
        XCTAssertEqual(events,[false,true])
        door.reset();_=door.update(position:SIMD3(0,0,-0.5),time:0,width:0.8,height:2,stable:true)
        XCTAssertNil(door.update(position:SIMD3(0,0,0.5),time:0.1,width:0.8,height:2,stable:true))
        door.reset();time=0
        for z:Float in [-0.4,-0.1,0.1,0.4] {
            XCTAssertNil(door.update(position:SIMD3(1.2,0,z),time:time,width:0.8,height:2,stable:true));time+=0.1
        }
    }
    func testForestRegistrationMatchesGeometryAndRejectsSymmetricRoom() throws {
        var pose=simd_float4x4(simd_quatf(angle:0.63,axis:SIMD3(0,1,0)));pose.columns.3=SIMD4(0.7,0.4,-1.2,1)
        func live(_ capture:RoomForestRegistration.Capture)->RoomForestRegistration.Capture {
            let walls=capture.walls.enumerated().filter{$0.offset != 1}.map { _,w -> RoomForestRegistration.Wall in
                let c=pose*SIMD4(w.center,1),n=pose*SIMD4(w.normal,0)
                return .init(center:SIMD3(c.x,c.y,c.z),normal:SIMD3(n.x,n.y,n.z),low:0,high:0,bottom:0,top:3)
            }
            let points=capture.points.filter{$0.p.x<3.95}.map { x -> RoomForestRegistration.Point in
                let p=pose*SIMD4(x.p,1),n=pose*SIMD4(x.n,0)
                return .init(p:SIMD3(p.x,p.y,p.z),n:SIMD3(n.x,n.y,n.z),kind:x.kind)
            }
            return .init(floor:0.4,walls:walls,points:points)
        }
        let source=roomFixture(),fit=try XCTUnwrap(RoomForestRegistration.fit(source:source,live:live(source)))
        XCTAssertLessThan(simd_distance(fit.pose.columns.3,pose.columns.3),0.02)
        XCTAssertGreaterThan(simd_dot(fit.pose.columns.0,pose.columns.0),0.999)
        let symmetric=roomFixture(detail:false)
        XCTAssertNil(RoomForestRegistration.fit(source:symmetric,live:live(symmetric)))
    }
    func testForestShotsStopAtCapturedWallsAndFurniture() {
        XCTAssertTrue(RoomForestShot.visible(target:1,obstacle:2))
        XCTAssertFalse(RoomForestShot.visible(target:2,obstacle:1))
        XCTAssertFalse(RoomForestShot.visible(target:nil,obstacle:1))
        XCTAssertFalse(RoomForestShot.visible(target:.nan,obstacle:1))
        XCTAssertTrue(RoomForestShot.visible(target:1,obstacle:nil))
    }
    func testForestGameAndDoorCommandsWorkLocallyAndRespectNegation() {
        for phrase in ["modo floresta","quarto tomado por floresta","transforma meu quarto numa floresta"] { XCTAssertEqual(WallARCommand.parse(phrase,inStudio:false),.roomForest(true)) }
        XCTAssertEqual(WallARCommand.parse("portal na porta",inStudio:false),.doorPortal)
        XCTAssertEqual(WallARCommand.parse("entrar no portal",inStudio:false),.roomForest(true))
        XCTAssertEqual(WallARCommand.parse("iniciar jogo da floresta",inStudio:false),.forestGame("start"))
        XCTAssertEqual(WallARCommand.parse("pausar jogo",inStudio:true),.forestGame("pause"))
        XCTAssertEqual(WallARCommand.parse("sair do jogo",inStudio:true),.forestGame("stop"))
        XCTAssertEqual(WallARCommand.parse("coloca um monstro",inStudio:true),.model("animated_bog_monster"))
        XCTAssertEqual(WallARCommand.parse("guardiao ataque",inStudio:true),.character("Attack"))
        XCTAssertEqual(WallARCommand.parse("coloca um golem",inStudio:true),.model("animated_stone_golem"))
        XCTAssertNil(WallARCommand.parse("não abrir portal",inStudio:true))
        XCTAssertNil(WallARCommand.parse("não iniciar jogo da floresta",inStudio:true))
        var record=SpatialPortalRecord(anchor:UUID(),width:0.8,height:2.15);record.doorway=true
        XCTAssertTrue(record.valid);record.doorway=false;XCTAssertFalse(record.valid)
    }
    @MainActor private func forestFixture()->(SCNGeometry,ScannedRoomManifest,Data) {
        let points:[SCNVector3]=[.init(-2,0,0),.init(2,0,0),.init(2,3,0),.init(-2,3,0),.init(0.7,0,0.6),.init(1.7,0,0.6),.init(1.7,1,0.6),.init(0.7,1,0.6),.init(-2,0,-2),.init(2,0,-2),.init(2,0,2),.init(-2,0,2)]
        let indices:[UInt32]=[0,1,2,0,2,3,4,5,6,4,6,7,8,10,9,8,11,10]
        let g=SCNGeometry(sources:[SCNGeometrySource(vertices:points),SCNGeometrySource(normals:(0..<12).map{ $0<8 ? SCNVector3(0,0,1) : SCNVector3(0,1,0) }),SCNGeometrySource(textureCoordinates:points.map{CGPoint(x:CGFloat($0.x),y:CGFloat($0.y))})],elements:[SCNGeometryElement(data:indices.withUnsafeBytes{Data($0)},primitiveType:.triangles,primitiveCount:6,bytesPerIndex:4)])
        let material=SCNMaterial();material.diffuse.contents=UIColor.brown;g.materials=[material]
        let manifest=ScannedRoomManifest(sourceSHA256:String(repeating:"0",count:64),mesh:"fixture",texture:"fixture",previewIndices:"fixture",facePlanes:"fixture",floorY:0,lower:[-2,0,-2],upper:[2,3,2],planes:[.init(id:0,kind:"wall",normal:[0,0,1],center:[0,1.5,0],indices:"fixture"),.init(id:1,kind:"floor",normal:[0,1,0],center:[0,0,0],indices:"fixture")],files:[])
        let faces:[Int32]=[0,0,-1,-1,1,1]
        return (g,manifest,faces.withUnsafeBytes{Data($0)})
    }
    @MainActor func testDoorCutPreservesCapturedFurnitureAndExactWallArea() {
        let (geometry,_,labels)=forestFixture()
        var pose=matrix_identity_float4x4;pose.columns.3.y=1
        let (cut,assignments)=RoomForestScene.cut(base:geometry,assignments:labels,opening:RoomDoorwayOpening(pose:pose,width:0.8,height:2))
        let p=RoomForestScene.points(cut),ids=RoomForestScene.indices(cut),kinds=assignments.withUnsafeBytes{b in (0..<(assignments.count/4)).map{b.loadUnaligned(fromByteOffset:$0*4,as:Int32.self)}}
        var wallArea:Float=0,furnitureArea:Float=0
        for i in kinds.indices {
            let a=p[Int(ids[i*3])],b=p[Int(ids[i*3+1])],c=p[Int(ids[i*3+2])],area=simd_length(simd_cross(b-a,c-a))/2
            if kinds[i]==0 { wallArea+=area };if kinds[i] == -1 { furnitureArea+=area }
        }
        XCTAssertEqual(wallArea,10.4,accuracy:0.001);XCTAssertEqual(furnitureArea,1,accuracy:0.001)
    }
    @MainActor func testForestAndGuardianRenderWithRealBoneAnimation() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let (g,manifest,labels)=forestFixture(),scene=SCNScene();scene.rootNode.addChildNode(RoomForestScene.make(base:g,manifest:manifest,assignments:labels))
        let model=try RoomForestGame.guardian(scale:1);model.position=SCNVector3(-0.45,0,1.1);scene.rootNode.addChildNode(model)
        XCTAssertTrue(SpatialRig.play(model,clip:"Roar"))
        XCTAssertTrue(SpatialRig.play(model,clip:"Die"))
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zNear=0.01;camera.camera?.zFar=20;camera.position=SCNVector3(2.5,2.0,4.5);camera.look(at:SCNVector3(0,0.9,0));scene.rootNode.addChildNode(camera)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=350;scene.rootNode.addChildNode(ambient)
        scene.lightingEnvironment.contents=Bundle.main.url(forResource:"Portal_forest_slope_2k",withExtension:"hdr")
        scene.lightingEnvironment.intensity=0.65
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        var images:[Data]=[]
        for fraction in [0.0,0.6] {
            try SpatialRig.previewPose(model,clip:"Attack",fraction:fraction)
            let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:800),antialiasingMode:.multisampling4X)
            images.append(try XCTUnwrap(image.pngData()))
            let attachment=XCTAttachment(image:image);attachment.name="Forest-guardian-native-\(fraction)";attachment.lifetime = .keepAlways;add(attachment)
        }
        XCTAssertNotEqual(images[0],images[1]);XCTAssertNotNil(SpatialRig.character(in:model))
    }

    @MainActor func testDetailedForestCreaturesKeepTheirMapsAndNativeClips() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        for id in SpatialRig.forestIdentifiers {
            let spec=try XCTUnwrap(SpatialAssets.bundled.first{$0["id"] as? String==id})
            XCTAssertGreaterThan(spec["triangles"] as? Int ?? 0,50000)
            let parts=try XCTUnwrap(spec["parts"] as? [[String:Any]])
            XCTAssertTrue(parts.contains{$0["NormalGL"] != nil})
            let model=try SpatialAssets.load(id)
            for clip in ["Idle","Walk","Run","Attack","Roar","Die"] { XCTAssertTrue(SpatialRig.play(model,clip:clip)) }
            try SpatialRig.previewPose(model,clip:"Idle",fraction:0.25)
            let scene=SCNScene();scene.background.contents=UIColor(red:0.07,green:0.10,blue:0.09,alpha:1);scene.rootNode.addChildNode(model)
            scene.lightingEnvironment.contents=Bundle.main.url(forResource:"Portal_forest_slope_2k",withExtension:"hdr");scene.lightingEnvironment.intensity=0.85
            let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(2.6,1.7,3.3);camera.look(at:SCNVector3(0,0.95,0));scene.rootNode.addChildNode(camera)
            let light=SCNNode();light.light=SCNLight();light.light?.type = .omni;light.light?.intensity=900;light.position=SCNVector3(2,4,3);scene.rootNode.addChildNode(light)
            let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
            let image=renderer.snapshot(atTime:0,with:CGSize(width:900,height:1000),antialiasingMode:.multisampling4X)
            let attachment=XCTAttachment(image:image);attachment.name="DETAILED-"+id;attachment.lifetime = .keepAlways;add(attachment)
        }
        let game=try RoomForestGame.guardian(scale:1)
        game.enumerateChildNodes { n,_ in if n.geometry != nil { XCTAssertNotEqual(n.categoryBitMask & 1,0);XCTAssertNotEqual(n.categoryBitMask & 64,0) } }
    }

    @MainActor func testCleanForestIsNotPunchedThroughByCapturedDepth() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let scene=SCNScene();scene.background.contents=UIColor.black
        let clean=SCNNode(geometry:SCNPlane(width:2,height:2));clean.geometry?.firstMaterial?.lightingModel = .constant;clean.geometry?.firstMaterial?.diffuse.contents=UIColor.green;scene.rootNode.addChildNode(clean)
        let raw=SCNNode(geometry:SCNPlane(width:2,height:2));raw.position.z=0.08;raw.renderingOrder = -50
        raw.geometry?.firstMaterial?.colorBufferWriteMask=[];scene.rootNode.addChildNode(raw)
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,3);scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        var values:[UInt8]=[]
        for forest in [false,true] {
            RoomForestScene.setCapturedDepth(try XCTUnwrap(raw.geometry),forest:forest)
            let image=renderer.snapshot(atTime:0,with:CGSize(width:400,height:400),antialiasingMode:.none)
            let cg=try XCTUnwrap(image.cgImage);var pixel=[UInt8](repeating:0,count:4)
            pixel.withUnsafeMutableBytes { bytes in
                let ctx=CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x:-200,y:-200);ctx.draw(cg,in:CGRect(x:0,y:0,width:400,height:400))
            }
            values.append(pixel[1])
            let attachment=XCTAttachment(image:image);attachment.name=forest ? "CLEAN-DEPTH-FIX" : "RAW-DEPTH-REPRO";attachment.lifetime = .keepAlways;add(attachment)
        }
        XCTAssertLessThan(values[0],30);XCTAssertGreaterThan(values[1],180)
    }

    func testPortalProjectionKeepsTheWallFixedAndChangesDepthWithViewpoint() throws {
        let w:Float=0.65,h:Float=0.85
        func project(_ point:SIMD3<Float>,eye:SIMD3<Float>)->SIMD2<Float> {
            let p=SpatialPortalMath.projection(eye:eye,width:w,height:h)!*SIMD4(point-eye,1)
            return SIMD2(p.x/p.w,p.y/p.w)
        }
        let a=SIMD3<Float>(0,0,1),b=SIMD3<Float>(0.6,0,1)
        for eye in [a,b,SIMD3(-1,0.4,2),SIMD3(2,0,3)] {
            let corner=project(SIMD3(w/2,h/2,0),eye:eye)
            XCTAssertEqual(corner.x,1,accuracy:0.0001);XCTAssertEqual(corner.y,1,accuracy:0.0001)
        }
        XCTAssertGreaterThan(abs(project(SIMD3(0,0,-2),eye:a).x-project(SIMD3(0,0,-2),eye:b).x),0.5)
        XCTAssertNil(SpatialPortalMath.projection(eye:SIMD3(0,0,-1),width:w,height:h))
        XCTAssertNil(SpatialPortalMath.projection(eye:SIMD3(.nan,0,1),width:w,height:h))
    }
    func testPortalRejectsAHoleInItsWallFootprint() {
        let full:[SIMD2<Float>]=[SIMD2(-1,-1),SIMD2(1,-1),SIMD2(1,1),SIMD2(-1,-1),SIMD2(1,1),SIMD2(-1,1)]
        XCTAssertTrue(SpatialPortalMath.fitsWall(width:0.65,height:0.85,triangles:full))
        XCTAssertFalse(SpatialPortalMath.fitsWall(width:0.65,height:0.85,triangles:Array(full.prefix(3))))
        XCTAssertFalse(SpatialPortalMath.fitsWall(width:0.65,height:0.85,triangles:[]))
    }
    func testPortalArchiveSurvivesRoundTripAndRejectsUnsafeDimensions() throws {
        let room=SpatialRoom(id:UUID(),name:"Quarto",origin:SpatialArchive.values(matrix_identity_float4x4))
        var archive=SpatialArchive(world:UUID(),rooms:[room],objects:[],panel:nil,map:Data([1]),saved:Date(),portal:SpatialPortalRecord(anchor:UUID(),width:0.65,height:0.85))
        try archive.validate()
        let copy=try JSONDecoder().decode(SpatialArchive.self,from:JSONEncoder().encode(archive))
        XCTAssertEqual(copy.portal,archive.portal)
        archive.portal?.height = .infinity;XCTAssertThrowsError(try archive.validate())
        archive.portal?.height=0.85;archive.portal?.theme="unknown";XCTAssertThrowsError(try archive.validate())
    }
    @MainActor func testFailedMapRecoveryPreservesTheArchiveAndUnlocksNewObjects() throws {
        let view=ARSCNView();view.scene=SCNScene();let world=SpatialWorld(view:view)
        world.restoredPortal=SpatialPortalRecord(anchor:UUID(),width:0.65,height:0.85)
        XCTAssertTrue(world.recovering)
        let before=try? Data(contentsOf:SpatialArchive.file)
        world.suspendSavedMap()
        XCTAssertFalse(world.recovering);XCTAssertTrue(world.preservingSavedMap)
        world.setModel("animated_fox");XCTAssertEqual(world.selectedModel,"animated_fox")
        world.saveMap();XCTAssertEqual(try? Data(contentsOf:SpatialArchive.file),before)
        world.stop()
    }
    func testPortalAndCatalogModelsHaveLocalVoiceRoutes() {
        XCTAssertEqual(WallARCommand.parse("abre um portal na parede",inStudio:false),.portal)
        XCTAssertEqual(WallARCommand.parse("fechar portal",inStudio:true),.closePortal)
        XCTAssertNil(WallARCommand.parse("não abrir portal",inStudio:true))
        for (phrase,id) in [("carro","toycar"),("sofa de couro","sheenwoodleathersofa"),("capacete espacial","scifihelmet"),("vaso de flores","glassvaseflowers"),("raposa","animated_fox")] {
            XCTAssertEqual(WallARCommand.parse("coloca um "+phrase,inStudio:true),.model(id))
        }
    }
    @MainActor func testPortalRendersAnIrregularClippedWorldWithParallax() async throws {
        guard let device=MTLCreateSystemDefaultDevice(),let portal=SpatialPortalRenderer(device:device) else { throw XCTSkip("Metal unavailable") }
        let scene=SCNScene();scene.background.contents=UIColor.black
        let hole=SCNNode(geometry:SpatialWallPortal.aperture(width:0.65,height:0.85));hole.geometry?.materials=[portal.material];scene.rootNode.addChildNode(hole)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=0.55;camera.position=SCNVector3(0,0,2);scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        var pictures:[Data]=[]
        for (i,eye) in [SIMD3<Float>(0,0,1),SIMD3<Float>(0.5,0.1,1)].enumerated() {
            portal.frame(eye:eye,width:0.65,height:0.85,time:Double(i)+1)
            for _ in 0..<40 { if portal.material.diffuse.contents is MTLTexture { break };try await Task.sleep(for:.milliseconds(50)) }
            try await Task.sleep(for:.milliseconds(200))
            XCTAssertTrue(portal.material.diffuse.contents is MTLTexture,"The live Metal target must replace the placeholder")
            let image=renderer.snapshot(atTime:Double(i)+1,with:CGSize(width:720,height:960),antialiasingMode:.multisampling4X)
            pictures.append(try XCTUnwrap(image.pngData()))
            let attachment=XCTAttachment(image:image);attachment.name="PORTAL-NATIVE-VIEW-"+String(i);attachment.lifetime = .keepAlways;add(attachment)
            let cg=try XCTUnwrap(image.cgImage);var pixels=[UInt8](repeating:0,count:128*128*4)
            let ctx=try XCTUnwrap(CGContext(data:&pixels,width:128,height:128,bitsPerComponent:8,bytesPerRow:512,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));ctx.draw(cg,in:CGRect(x:0,y:0,width:128,height:128))
            XCTAssertEqual(pixels[0],0,"Scene outside the aperture stays black")
            XCTAssertGreaterThan(stride(from:0,to:pixels.count,by:4).filter{max(pixels[$0],pixels[$0+1],pixels[$0+2])>45}.count,1000)
        }
        XCTAssertNotEqual(pictures[0],pictures[1],"A viewpoint change must reveal different 3D content")
    }
    func testHandsFreePlacementNeedsStablePointAndNeverUsesPinch() {
        var gesture=SpatialAimSelection(),clicks:[String]=[]
        for i in 0...25 {
            if let id=gesture.update(target:"floor",point:CGPoint(x:100,y:200),pointing:true,time:Double(i)/10) { clicks.append(id) }
        }
        XCTAssertEqual(clicks,["floor"])
        XCTAssertNil(gesture.update(target:"floor",point:CGPoint(x:100,y:200),pointing:false,time:2.6))
        for i in 27...42 { XCTAssertNil(gesture.update(target:"floor",point:CGPoint(x:100,y:200),pointing:true,time:Double(i)/10)) }
        XCTAssertNil(gesture.update(target:"floor",point:CGPoint(x:140,y:200),pointing:true,time:4.3),"Moving the aiming point must restart placement dwell")
        XCTAssertLessThan(gesture.progress,0.1)
        gesture.reset()
        for i in 0...30 { XCTAssertNil(gesture.update(target:"floor",point:CGPoint(x:100,y:200),pointing:false,time:Double(i)/10),"A free hand or pinch cannot place an object") }
    }
    func testLiveLiDARPaintExcludesDoorWindowFurnitureAndOffPlaneFaces() {
        let triangle:[SIMD3<Float>]=[SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)]
        let normal=SIMD3<Float>(0,0,1)
        XCTAssertTrue(LiveWallRegion.accepts(triangle,classification:ARMeshClassification.wall.rawValue,origin:.zero,normal:normal))
        for kind in [ARMeshClassification.door,.window,.floor,.ceiling,.table,.seat,.none] {
            XCTAssertFalse(LiveWallRegion.accepts(triangle,classification:kind.rawValue,origin:.zero,normal:normal),"Never paint \(kind)")
        }
        XCTAssertFalse(LiveWallRegion.accepts(triangle.map{$0+SIMD3(0,0,0.10)},classification:ARMeshClassification.wall.rawValue,origin:.zero,normal:normal))
        XCTAssertFalse(LiveWallRegion.accepts(triangle,classification:ARMeshClassification.wall.rawValue,origin:.zero,normal:SIMD3(1,0,0)))
        XCTAssertFalse(LiveWallRegion.accepts([.zero,.zero,.zero],classification:ARMeshClassification.wall.rawValue,origin:.zero,normal:normal))
    }
    func testFullFistOpensCatalogOnceAndNeedsDeliberateRelease() {
        var gesture=SpatialFistMenuGesture(),events=0
        for i in 0...30 { if gesture.update(closed:true,time:Double(i)*0.1) { events+=1 } }
        XCTAssertEqual(events,1)
        XCTAssertFalse(gesture.update(closed:nil,time:3.01))
        XCTAssertFalse(gesture.update(closed:true,time:3.02),"Occlusion cannot reopen a held fist")
        XCTAssertFalse(gesture.update(closed:false,time:3.1))
        XCTAssertFalse(gesture.update(closed:false,time:3.4))
        for i in 35...44 { if gesture.update(closed:true,time:Double(i)*0.1) { events+=1 } }
        XCTAssertEqual(events,2)
        var interrupted=SpatialFistMenuGesture()
        XCTAssertFalse(interrupted.update(closed:true,time:0))
        XCTAssertFalse(interrupted.update(closed:true,time:0.2))
        XCTAssertFalse(interrupted.update(closed:true,time:1.2))
        XCTAssertFalse(interrupted.update(closed:true,time:.nan))
    }
    func testFullFistRejectsOpenHandAndPinchIndependentlyOfRotation() {
        var hand=[CGPoint?](repeating:nil,count:21)
        hand[0]=CGPoint(x:100,y:140);hand[4]=CGPoint(x:103,y:105)
        for (offset,base) in [5,9,13,17].enumerated() {
            let x=CGFloat(70+offset*20)
            hand[base]=CGPoint(x:x,y:100);hand[base+1]=CGPoint(x:x,y:75);hand[base+3]=CGPoint(x:x,y:110)
        }
        XCTAssertTrue(SpatialHandMath.closedFist(hand))
        let rotated=hand.map{$0.map{CGPoint(x:-$0.y,y:$0.x)}}
        XCTAssertTrue(SpatialHandMath.closedFist(rotated))
        for base in [5,9,13,17] { hand[base+3]=CGPoint(x:hand[base]!.x,y:20) }
        XCTAssertFalse(SpatialHandMath.closedFist(hand))
        hand[8]=hand[4]
        XCTAssertFalse(SpatialHandMath.closedFist(hand),"Pinch remains a drag gesture")
        XCTAssertFalse(SpatialHandMath.closedFist([]))
    }
    func testRoomRegistrationPreservesMetricScaleAndRejectsBadMatches() throws {
        let source:[SIMD3<Float>]=[SIMD3(0,0,0),SIMD3(2,0,0),SIMD3(0,0,2)]
        var expected=simd_float4x4(simd_quatf(angle:0.7,axis:SIMD3(0,1,0)));expected.columns.3=SIMD4(3,0.4,-2,1)
        let target=source.map{p -> SIMD3<Float> in let q=expected*SIMD4(p,1);return SIMD3(q.x,q.y,q.z)}
        let fit=try XCTUnwrap(SpatialRoomAlignment.fit(source:source,target:target))
        for p in source { XCTAssertLessThan(simd_length(fit*SIMD4(p,1)-expected*SIMD4(p,1)),0.001) }
        XCTAssertNil(SpatialRoomAlignment.fit(source:source,target:source.map{$0*1.4}))
        XCTAssertNil(SpatialRoomAlignment.fit(source:[.zero,SIMD3(1,0,0),SIMD3(2,0,0)],target:target))
        XCTAssertNil(SpatialRoomAlignment.fit(source:source,target:[.zero,SIMD3(2,1,0),SIMD3(0,0,2)]))
        XCTAssertEqual(WallARCommand.parse("abrir catálogo de efeitos",inStudio:true),.effects)
        XCTAssertEqual(WallARCommand.parse("testar parede branca",inStudio:true),.roomWall("white"))
    }
    @MainActor func testEffectsCatalogRendersSixRadialSectorsWithRealActions() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:1000,height:900));view.scene=SCNScene()
        let panel=SpatialPanel(view:view);panel.previewEffectsCatalog()
        XCTAssertTrue(panel.showingEffectsCatalog)
        let sectors=view.scene.rootNode.childNodes.flatMap(\.childNodes).filter{$0.name?.hasPrefix("radial-sector:")==true}
        XCTAssertEqual(sectors.count,6)
        XCTAssertTrue(sectors.allSatisfy{$0.geometry is SCNShape})
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=0.34
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.position=SCNVector3(0,0,1)
        view.scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:900),antialiasingMode:.multisampling4X)
        let cg=try XCTUnwrap(image.cgImage)
        var pixels=[UInt8](repeating:0,count:256*256*4)
        let context=try XCTUnwrap(CGContext(data:&pixels,width:256,height:256,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:CGRect(x:0,y:0,width:256,height:256))
        XCTAssertGreaterThan(stride(from:0,to:pixels.count,by:4).filter{max(pixels[$0],pixels[$0+1],pixels[$0+2])>100}.count,100,"The radial catalog must have visible glyphs, not just geometry nodes")
        let attachment=XCTAttachment(image:image);attachment.name="JARVIS-FIST-EFFECTS-RADIAL";attachment.lifetime = .keepAlways;add(attachment)
        try image.pngData()?.write(to:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("JARVIS-FIST-EFFECTS-RADIAL.png"))
        panel.close()
    }
    func testDesktopSurvivesLoadingAMapThatPredatesTheWindow() {
        var intent=SpatialDesktopResumeIntent()
        intent.prepare(wasOpen:true,savedWindow:false)
        XCTAssertFalse(intent.consume(cameraStable:false,savedWindowPending:false))
        XCTAssertTrue(intent.pending)
        XCTAssertTrue(intent.consume(cameraStable:true,savedWindowPending:false))
        XCTAssertFalse(intent.consume(cameraStable:true,savedWindowPending:false))
        intent.prepare(wasOpen:true,savedWindow:true)
        XCTAssertFalse(intent.consume(cameraStable:true,savedWindowPending:true),"A saved physical anchor must win over a new camera-relative window")
        intent.prepare(wasOpen:false,savedWindow:false)
        XCTAssertFalse(intent.consume(cameraStable:true,savedWindowPending:false))
    }
    func testCameraTrackingDoesNotClaimTheSavedMapIsLocalized() {
        var state=SpatialLocalizationReadiness(cameraStable:true,pendingObjects:0,pendingPanel:false,pendingDesktop:true)
        XCTAssertFalse(state.localized);XCTAssertFalse(state.desktopReady)
        state.pendingDesktop=false;state.pendingObjects=1
        XCTAssertFalse(state.localized);XCTAssertTrue(state.desktopReady,"An unrelated pending object must not hide an already restored desktop")
        state.pendingObjects=0;XCTAssertTrue(state.localized)
        state.cameraStable=false;XCTAssertFalse(state.localized);XCTAssertFalse(state.desktopReady)
    }
    @MainActor func testShutdownPreservesWindowAnchorsForThePendingWorldMapSnapshot() {
        final class RecordingSession:ARSession {
            var removed:[UUID]=[]
            override func remove(anchor:ARAnchor) { removed.append(anchor.identifier) }
        }
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900)),session=RecordingSession()
        view.scene=SCNScene();view.session=session
        let desktop=SpatialDesktop(view:view);desktop.preview()
        XCTAssertNotNil(desktop.snapshot());desktop.close(recordChange:false,preserveAnchor:true)
        XCTAssertTrue(session.removed.isEmpty)
        desktop.preview();desktop.close();XCTAssertEqual(session.removed.count,1)
        let panel=SpatialPanel(view:view),anchor=ARAnchor(name:"JarvisControlPanel",transform:matrix_identity_float4x4)
        panel.restore(SpatialPanelRecord(anchor:anchor.identifier,module:"dashboard",scale:0.5),anchor:anchor)
        panel.close(recordChange:false,preserveAnchor:true);XCTAssertEqual(session.removed.count,1)
    }
    func testGPSRanksNearbyMapsWithoutPretendingToProvideAnIndoorPose() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let current=SpatialMapLocation(latitude:0,longitude:0,accuracy:10,timestamp:Date())
        let near=SpatialMapLocation(latitude:0,longitude:0.0001,accuracy:10,timestamp:Date())
        let far=SpatialMapLocation(latitude:1,longitude:1,accuracy:10,timestamp:Date())
        let urls=[directory.appendingPathComponent("far.json"),directory.appendingPathComponent("near.json")]
        for (url,location) in zip(urls,[far,near]) {
            try JSONEncoder().encode(SpatialMapSummary(world:UUID(),saved:Date(),location:location)).write(to:url.appendingPathExtension("mapinfo"))
        }
        XCTAssertEqual(SpatialArchive.savedMaps(near:current,candidates:urls),[urls[1],urls[0]])
        var uncertain=current;uncertain.accuracy=1000
        XCTAssertEqual(SpatialArchive.savedMaps(near:uncertain,candidates:urls),urls)
        XCTAssertEqual(current.separation(from:near),0)
    }
    @MainActor func testUnavailableModelDoesNotBlockTheRestoredDesktop() {
        let controller=WallARController(),id=UUID(),anchor=ARAnchor(name:"JarvisDesktop",transform:matrix_identity_float4x4)
        let missing=ARAnchor(name:"JarvisObject:"+id.uuidString,transform:matrix_identity_float4x4)
        controller.spatial.queueRestoration([SpatialObjectRecord(id:id,model:"not_in_the_asset_catalog",room:UUID(),anchor:missing.identifier,localTransform:SpatialArchive.values(matrix_identity_float4x4),scale:1,updated:Date())])
        controller.spatial.restoredDesktop=SpatialDesktopRecord(anchor:anchor.identifier,scale:0.7)
        XCTAssertTrue(controller.spatial.recovering)
        controller.receiveTrackedAnchors([missing,anchor])
        XCTAssertNotNil(controller.desktop.snapshot())
        XCTAssertFalse(controller.spatial.recovering)
        XCTAssertTrue(controller.spatial.readiness(cameraStable:true).desktopReady)
        XCTAssertEqual(controller.spatial.unavailableModels[id],"not_in_the_asset_catalog")
        controller.stop()
    }
    func testProjectedTypingKeepsItsShortDwellAfterResetAndScrollingHasNoClickEvent() {
        var key=SpatialGesture(dwellDuration:0.55)
        var typed:[SpatialGesture.Event]=[]
        for tick in 0...6 { typed += key.update(ratio:1,pointing:true,target:"q",time:Double(tick)*0.1) }
        XCTAssertEqual(typed,[.click("q")]);key.reset();typed=[]
        for tick in 10...16 { typed += key.update(ratio:1,pointing:true,target:"q",time:Double(tick)*0.1) }
        XCTAssertEqual(typed,[.click("q")])
        var scroll=SpatialDesktopScroll()
        XCTAssertNil(scroll.update(point:CGPoint(x:0.5,y:0.5),time:0))
        XCTAssertLessThan(scroll.update(point:CGPoint(x:0.5,y:0.4),time:0.1) ?? 0,0)
        XCTAssertNil(scroll.update(point:nil,time:0.2))
        XCTAssertNil(scroll.update(point:CGPoint(x:0.5,y:0.2),time:1))
    }
    @MainActor func testProjectedDesktopKeyboardAndInputQueueKeepLettersInOrder() throws {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900));view.scene=SCNScene()
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,1)
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.fieldOfView=60
        view.scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let desktop=SpatialDesktop(view:view);desktop.preview()
        var jobs:[[String:Any]]=[];desktop.send={jobs.append($0)}
        desktop.toggleKeyboard();XCTAssertTrue(desktop.keyboardVisible)
        func type(_ letter:String,from start:Double) throws {
            let node=try XCTUnwrap(view.scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name=="desktop-ui:text-"+letter })
            let projected=view.projectPoint(node.worldPosition)
            for tick in 0...8 {
                _=desktop.hand(SpatialHandSample(point:CGPoint(x:CGFloat(projected.x),y:CGFloat(projected.y)),ratio:1,menuPose:false,pointing:true,time:start+Double(tick)*0.1))
            }
        }
        try type("q",from:0);try type("w",from:1)
        XCTAssertEqual(jobs.count,1);XCTAssertEqual(jobs[0]["text"] as? String,"q")
        desktop.receive(try JSONSerialization.data(withJSONObject:["requestId":jobs[0]["requestId"]!,"ok":true,"sequence":1]))
        XCTAssertEqual(jobs.count,2);XCTAssertEqual(jobs[1]["text"] as? String,"w")
        if let device=MTLCreateSystemDefaultDevice() {
            let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
            let image=renderer.snapshot(atTime:0,with:CGSize(width:600,height:900),antialiasingMode:.multisampling2X)
            let attachment=XCTAttachment(image:image);attachment.name="Desktop-projected-keyboard";attachment.lifetime = .keepAlways;add(attachment)
        }
        desktop.close(recordChange:false)
    }
    @MainActor func testTwoFingerDesktopScrollNeverClicksOrMovesTheWindow() throws {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900));view.scene=SCNScene()
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,1)
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.fieldOfView=60;view.scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let desktop=SpatialDesktop(view:view);desktop.preview()
        var jobs:[[String:Any]]=[];desktop.send={jobs.append($0)}
        let original=desktop.previewPosition
        for tick in 0...3 { _=desktop.hand(SpatialHandSample(point:CGPoint(x:300,y:450-tick*10),ratio:1,menuPose:true,pointing:false,time:Double(tick)*0.1)) }
        XCTAssertFalse(jobs.isEmpty);XCTAssertTrue(jobs.allSatisfy { $0["action"] as? String == "scroll" })
        XCTAssertEqual(desktop.previewPosition,original);XCTAssertFalse(desktop.isDragging)
        desktop.close(recordChange:false)
    }
    @MainActor func testMovingIndexOnDesktopDoesNotClickAfterTwoSeconds() {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900));view.scene=SCNScene()
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,1)
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.fieldOfView=60;view.scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let desktop=SpatialDesktop(view:view);desktop.preview()
        var jobs:[[String:Any]]=[];desktop.send={jobs.append($0)}
        for tick in 0...30 { _=desktop.hand(SpatialHandSample(point:CGPoint(x:260+tick*2,y:450),ratio:1,menuPose:false,pointing:true,time:Double(tick)*0.1)) }
        XCTAssertTrue(jobs.isEmpty);desktop.close(recordChange:false)
    }
    func testNormalTrackingDoesNotRecoverForeverBecauseRenderFramesAreSlow() {
        var pose=SpatialPoseStability(),gate=WallTrackingGate()
        for tick in 0...20 {
            let time=Double(tick)*0.5
            let stable=pose.update(position:SIMD3(0,0,0),forward:SIMD3(0,0,1),time:time)
            XCTAssertTrue(stable)
            if tick>1 { XCTAssertTrue(gate.update(normal:stable,at:time)) }
            else { _=gate.update(normal:stable,at:time) }
        }
    }
    func testTwoPinchesResizeWithoutReusingAReleasedHand() {
        var gate=SpatialDualPinchScale(),scale:Float=1
        for tick in 0...30 {
            scale *= gate.update(points:[CGPoint(x:0,y:0),CGPoint(x:100+tick*5,y:0)],time:Double(tick)*0.1) ?? 1
        }
        XCTAssertGreaterThan(scale,2);XCTAssertTrue(gate.active)
        XCTAssertNil(gate.update(points:nil,time:3.2));XCTAssertTrue(gate.active)
        XCTAssertNil(gate.update(points:nil,time:3.5));XCTAssertFalse(gate.active)
    }
    @MainActor func testCleanProjectionLeavesOneIconAndDwellOpensRadialOnce() throws {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900));view.scene=SCNScene()
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,1)
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.fieldOfView=60
        view.scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let panel=SpatialPanel(view:view);panel.preview(.dashboard);panel.setTracking(true)
        let root=try XCTUnwrap(view.scene.rootNode.childNodes.first { $0.childNodes.contains { $0.geometry is SCNPlane } })
        let clean=try XCTUnwrap(root.childNodes.first { $0.name?.contains("hideInterface") == true })
        let screen=view.projectPoint(clean.worldPosition)
        XCTAssertTrue(panel.hit(CGPoint(x:CGFloat(screen.x),y:CGFloat(screen.y))))
        XCTAssertTrue(panel.immersive);XCTAssertEqual(root.childNodes.count,1)
        XCTAssertEqual(root.childNodes.first?.name,"immersive-orb")
        XCTAssertFalse(panel.contains(CGPoint(x:10,y:10)))
        var images:[UIImage]=[]
        func capture() {
            guard let device=MTLCreateSystemDefaultDevice() else { return }
            let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
            images.append(renderer.snapshot(atTime:0,with:CGSize(width:600,height:900),antialiasingMode:.multisampling2X))
        }
        capture()
        func dwell(_ tick:Int,pointing:Bool=true) {
            panel.hand(SpatialHandSample(point:CGPoint(x:300,y:450),ratio:1,menuPose:false,pointing:pointing,time:Double(tick)*0.1))
        }
        for tick in 0...20 { dwell(tick) }
        XCTAssertEqual(root.childNodes.count,1,"The menu must wait the full two seconds")
        for tick in 21...55 { dwell(tick) }
        XCTAssertGreaterThan(root.childNodes.count,6,"Holding the same icon must open once without collapsing again")
        XCTAssertTrue(panel.immersive);capture()
        dwell(56,pointing:false)
        for tick in 57...80 { dwell(tick) }
        XCTAssertEqual(root.childNodes.count,1)
        for tick in 81...110 { dwell(tick,pointing:false) }
        XCTAssertEqual(root.childNodes.count,1,"A free open hand does not click")
        if images.count==2 {
            let format=UIGraphicsImageRendererFormat();format.scale=1
            let atlas=UIGraphicsImageRenderer(size:CGSize(width:1200,height:900),format:format).image { _ in
                images[0].draw(at:.zero);images[1].draw(at:CGPoint(x:600,y:0))
            }
            let attachment=XCTAttachment(image:atlas);attachment.name="Spatial-clean-icon-and-radial-menu";attachment.lifetime = .keepAlways;add(attachment)
        }
        panel.close();XCTAssertFalse(panel.immersive)
    }
    func testPointingCanDwellOnAnotherButtonWithoutReleasingTheHand() {
        var gesture=SpatialGesture(),clicks:[SpatialGesture.Event]=[]
        for tick in 0...55 {
            clicks += gesture.update(ratio:1,pointing:true,target:tick<28 ? "first" : "second",time:Double(tick)*0.1)
        }
        XCTAssertEqual(clicks,[.click("first"),.click("second")])
    }
    func testFrameCallbackAndDisplayPollDoNotDuplicateOrReplayFrames() {
        var gate=SpatialFrameGate()
        XCTAssertTrue(gate.accept(10));XCTAssertFalse(gate.accept(10))
        XCTAssertFalse(gate.accept(9));XCTAssertFalse(gate.accept(.nan))
        XCTAssertTrue(gate.accept(10.02));XCTAssertFalse(gate.accept(10.02))
    }
    func testStationaryPinchNoiseDoesNotAccumulateZoomAndDepthDoesNotSwitchSources() {
        var zoom=SpatialPinchZoom()
        zoom.begin(span:0.2,depth:nil,time:0)
        for tick in 1...600 {
            let span=0.2*(1+sin(Double(tick))*0.035)
            XCTAssertNil(zoom.update(span:span,depth:nil,time:Double(tick)*0.1))
        }
        zoom.begin(span:0.2,depth:0.6,time:61)
        XCTAssertNil(zoom.update(span:0.6,depth:nil,time:61.1))
        XCTAssertNil(zoom.update(span:0.6,depth:0.6,time:61.2))
        var size:Float=1
        for tick in 1...20 {
            let factor=zoom.update(span:0.6,depth:0.6-Double(tick)*0.015,time:61.2+Double(tick)*0.1) ?? 1
            XCTAssertLessThanOrEqual(factor,1.084);size*=factor
        }
        XCTAssertGreaterThan(size,1.5)
    }
    func testCameraPoseJumpWaitsToSettleWithoutFreezingNormalMovement() {
        var gate=SpatialPoseStability()
        for tick in 0...60 {
            XCTAssertTrue(gate.update(position:SIMD3(Float(tick)*0.001,0,0),forward:SIMD3(0,0,1),time:Double(tick)/60))
        }
        XCTAssertFalse(gate.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:61.0/60))
        for tick in 62...107 {
            XCTAssertFalse(gate.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:Double(tick)/60))
        }
        XCTAssertTrue(gate.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:110.0/60))
        XCTAssertTrue(gate.update(position:SIMD3(1,0,0),forward:SIMD3(0,0,1),time:5),"A late frame alone is not a localization failure")
    }
    @MainActor func testHeadsetSharesOneCameraSessionAndRestoresFullViewport() async throws {
        let controller=WallARController(),host=SpatialHeadsetSurface(controller:controller)
        host.frame=CGRect(x:0,y:0,width:900,height:400)
        let session=controller.view.session
        host.configure(headset:true);host.layoutIfNeeded()
        XCTAssertNotNil(host.output);XCTAssertNotNil(host.compositor)
        XCTAssertFalse(controller.view.isHidden);XCTAssertFalse(controller.view.isPlaying)
        XCTAssertFalse(controller.view.rendersContinuously)
        XCTAssertTrue(controller.view.session === session)
        XCTAssertEqual(host.eyeFrames[0].width,438);XCTAssertEqual(host.eyeFrames[1].minX,462)
        XCTAssertEqual(controller.view.frame.width,438)
        XCTAssertEqual(host.eyes.count,2)
        XCTAssertTrue(host.eyes.allSatisfy{$0.clipsToBounds})
        XCTAssertFalse(host.eyes[0].video === host.eyes[1].video)
        XCTAssertEqual(host.eyes[0].frame.width,438)
        XCTAssertEqual(host.eyes[1].frame.minX,462)
        let anchor=ARAnchor(name:"headset-event-probe",transform:simd_float4x4(SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,1,0),SIMD4(0.3,0,0,1)))
        let marker=SCNNode();controller.worldAnchor=anchor;controller.painted=marker
        controller.receiveTrackedAnchors([anchor]);XCTAssertEqual(marker.position.x,0.3,accuracy:0.001)
        host.configure(headset:false);host.layoutIfNeeded()
        XCTAssertNil(host.output);XCTAssertFalse(controller.view.isHidden)
        XCTAssertTrue(controller.view.session === session);XCTAssertEqual(controller.view.frame.width,900)
        marker.position=SCNVector3(-9,0,0);controller.receiveTrackedAnchors([anchor])
        XCTAssertEqual(marker.position.x,0.3,accuracy:0.001)
        controller.stop()
    }
    @MainActor func testHeadsetTogglePropagatesThroughSwiftUIWithoutDirectConfigureCalls() async throws {
        struct Harness:View {
            @ObservedObject var controller:WallARController
            var body:some View {
                ZStack {
                    WallCameraView(controller:controller,headset:controller.headset).frame(maxWidth:.infinity,maxHeight:.infinity)
                    if controller.headset { Text("Sair VR").allowsHitTesting(false) }
                }
            }
        }
        let controller=WallARController(),window=UIWindow(frame:UIScreen.main.bounds)
        let hosting=UIHostingController(rootView:Harness(controller:controller))
        window.rootViewController=hosting;window.makeKeyAndVisible()
        defer { controller.stop();window.isHidden=true }
        func surface(_ view:UIView)->SpatialHeadsetSurface? {
            if let host=view as? SpatialHeadsetSurface { return host }
            return view.subviews.lazy.compactMap{surface($0)}.first
        }
        try await Task.sleep(for:.milliseconds(300));hosting.view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(surface(hosting.view)).eyes.count,0)
        controller.headset=true
        try await Task.sleep(for:.milliseconds(500));hosting.view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(surface(hosting.view)).eyes.count,2)
        controller.headset=false
        try await Task.sleep(for:.milliseconds(300));hosting.view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(surface(hosting.view)).eyes.count,0)
    }
    @MainActor func testHoloVideoLayersDisplayBothEyesWithoutWaitingForWorldTracking() async throws {
        guard #available(iOS 17.4,*) else { throw XCTSkip("Video presentation readiness is exposed from iOS 17.4") }
        let controller=WallARController(),host=SpatialHeadsetSurface(controller:controller)
        let window=UIWindow(frame:UIScreen.main.bounds),root=UIViewController()
        window.rootViewController=root;window.makeKeyAndVisible()
        root.view.backgroundColor = .black
        host.frame=CGRect(x:0,y:100,width:window.bounds.width,height:320)
        root.view.addSubview(host);host.configure(headset:true);host.layoutIfNeeded()
        defer { host.configure(headset:false);controller.stop();window.isHidden=true }
        var buffer:CVPixelBuffer?
        let attrs:[CFString:Any]=[kCVPixelBufferIOSurfacePropertiesKey:[:]]
        XCTAssertEqual(CVPixelBufferCreate(nil,240,320,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&buffer),kCVReturnSuccess)
        let pixels=try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels,[])
        let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to:UInt8.self)
        let colors:[[UInt8]]=[[0,0,255,255],[0,255,0,255],[255,0,0,255],[0,255,255,255]]
        for y in 0..<320 { for x in 0..<240 { for c in 0..<4 { bytes[y*CVPixelBufferGetBytesPerRow(pixels)+x*4+c]=colors[x/60][c] } } }
        CVPixelBufferUnlockBaseAddress(pixels,[])
        for tick in 0..<30 {
            XCTAssertTrue(host.displayCamera(pixels,orientation:.landscapeRight,time:Double(tick)/30))
            try await Task.sleep(for:.milliseconds(33))
        }
        XCTAssertFalse(controller.videoRunning,"No world session was started for this camera-only proof")
        XCTAssertTrue(host.eyes.allSatisfy{$0.cameraFrames>0})
        XCTAssertTrue(host.eyes.allSatisfy{$0.video.isReadyForDisplay},"Both physical video layers must present, not only the shader test")
        // Read the frame actually displayed by each renderer. XCUIScreen is a
        // UI-test API and aborts an ordinary hosted XCTest process.
        let displayed=try host.eyes.map { try XCTUnwrap($0.video.sampleBufferRenderer.displayedPixelBuffer()) }
        let images=try displayed.map { try XCTUnwrap(CIContext().createCGImage(CIImage(cvPixelBuffer:$0),from:CGRect(x:0,y:0,width:240,height:320))) }
        XCTAssertEqual(UIImage(cgImage:images[0]).pngData(),UIImage(cgImage:images[1]).pngData())
        for (i,image) in images.enumerated() { let attachment=XCTAttachment(image:UIImage(cgImage:image));attachment.name="Holo-displayed-eye-\(i)";attachment.lifetime = .keepAlways;add(attachment) }
        host.frame.size=CGSize(width:400,height:250);host.setNeedsLayout();host.layoutIfNeeded()
        XCTAssertEqual(host.eyes[0].frame.width,188);XCTAssertEqual(host.eyes[1].frame.minX,212)
    }
    @MainActor func testHeadsetCompositorRepeatsWholeCameraAndScenePerEye() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let compositor=try SpatialEyeCompositor(device:device)
        var pixelBuffer:CVPixelBuffer?
        let properties:[CFString:Any]=[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]]
        let attributes=properties as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,attributes,&pixelBuffer),kCVReturnSuccess)
        let pixels=try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels,[])
        let colors:[(UInt8,UInt8,UInt8)]=[(76,85,255),(150,44,21),(29,255,107),(226,0,149)]
        let y=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels,0)).assumingMemoryBound(to:UInt8.self)
        let uv=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels,1)).assumingMemoryBound(to:UInt8.self)
        for row in 0..<32 { for x in 0..<32 { y[row*CVPixelBufferGetBytesPerRowOfPlane(pixels,0)+x]=colors[x/8].0 } }
        for row in 0..<16 { for x in 0..<16 {
            let i=row*CVPixelBufferGetBytesPerRowOfPlane(pixels,1)+x*2
            uv[i]=colors[x/4].1;uv[i+1]=colors[x/4].2
        } }
        CVPixelBufferUnlockBaseAddress(pixels,[])
        let size=CGSize(width:820,height:400),eyes=SpatialEyeLayout.frames(size:size,gap:20)
        let scene=SCNScene(),cube=SCNNode(geometry:SCNBox(width:0.16,height:0.16,length:0.16,chamferRadius:0))
        cube.position=SCNVector3(0,0,-1);cube.geometry?.firstMaterial?.lightingModel = .constant;cube.geometry?.firstMaterial?.diffuse.contents=UIColor.white;scene.rootNode.addChildNode(cube)
        let f:Float=1/tan(.pi/6),projection=simd_float4x4(SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,-1.001,-1),SIMD4(0,0,-0.02001,0))
        for rotated in [false,true] {
            let spec=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:820,height:400,mipmapped:false)
            spec.storageMode = .shared;spec.usage = .renderTarget
            let target=try XCTUnwrap(device.makeTexture(descriptor:spec)),command=try XCTUnwrap(compositor.queue.makeCommandBuffer())
            let world=try XCTUnwrap(compositor.renderWorld(scene:scene,transform:matrix_identity_float4x4,projection:projection,size:eyes[0].size,time:0,command:command))
            let transform=rotated ? CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:1,ty:1) : .identity
            XCTAssertTrue(compositor.compose(pixels:pixels,displayToCamera:transform,world:world,destination:target,eyes:eyes,command:command))
            command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
            var bytes=[UInt8](repeating:0,count:820*400*4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:820*4,from:MTLRegionMake2D(0,0,820,400),mipmapLevel:0) }
            var mismatch=0
            for row in 0..<400 { for x in 0..<400 {
                let a=(row*820+x)*4,b=(row*820+420+x)*4
                if bytes[a..<a+4] != bytes[b..<b+4] { mismatch+=1 }
            } }
            XCTAssertEqual(mismatch,0,"Each eye must contain the same complete composite")
            for x in 400..<420 { XCTAssertEqual(Array(bytes[(200*820+x)*4..<(200*820+x)*4+4]),[0,0,0,255]) }
            func rgb(_ x:Int,_ row:Int)->[UInt8] { let i=(row*820+x)*4;return [bytes[i+2],bytes[i+1],bytes[i]] }
            let expected=rotated ? [[1,1,0],[0,0,1],[0,1,0],[1,0,0]] : [[1,0,0],[0,1,0],[0,0,1],[1,1,0]]
            for stripe in 0..<4 { let sample=rgb(stripe*100+50,360);for channel in 0..<3 {
                if expected[stripe][channel]==1 { XCTAssertGreaterThan(sample[channel],180) } else { XCTAssertLessThan(sample[channel],80) }
            } }
            XCTAssertTrue(rgb(200,200).allSatisfy { $0>200 },"The 3D object must be composed over the camera in both eyes")
            let info=CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue))
            let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
            let image=UIImage(cgImage:try XCTUnwrap(CGImage(width:820,height:400,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:820*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)))
            let name=rotated ? "JARVIS-VRBOX-GPU-ROTATED" : "JARVIS-VRBOX-GPU"
            let attachment=XCTAttachment(image:image);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
            try image.pngData()?.write(to:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(name+".png"))
        }
    }
    func testHeadsetVoiceCommandsAndNegation() {
        XCTAssertEqual(WallARCommand.parse("recuperar sem apagar",inStudio:true),.recover)
        XCTAssertEqual(WallARCommand.parse("abrir teclado",inStudio:true),.keyboard(true))
        XCTAssertEqual(WallARCommand.parse("fechar teclado",inStudio:true),.keyboard(false))
        XCTAssertEqual(WallARCommand.parse("Jarvis, ativar VR Box",inStudio:false),.headset(true))
        XCTAssertEqual(WallARCommand.parse("modo óculos",inStudio:false),.headset(true))
        XCTAssertEqual(WallARCommand.parse("sair do VR Box",inStudio:true),.headset(false))
        XCTAssertNil(WallARCommand.parse("não ativar VR Box",inStudio:true))
    }
    @MainActor func testRecoveryOffersExitWhenTrackingOrSavedAnchorsCannotReturn() async throws {
        for tracking in [false,true] {
            let controller=WallARController()
            controller.previewRecovery(tracking:tracking,anchorsPending:tracking,delay:.milliseconds(30))
            XCTAssertFalse(controller.localizationTimedOut)
            for _ in 0..<40 {
                if controller.localizationTimedOut { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(controller.localizationTimedOut)
            controller.stop()
        }
        let stopped=WallARController()
        stopped.previewRecovery(tracking:false,anchorsPending:false,delay:.milliseconds(30))
        stopped.stop();try await Task.sleep(for:.milliseconds(120))
        XCTAssertFalse(stopped.localizationTimedOut)
    }
    @MainActor func testAnimatedCharactersRenderDistinctPoses() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let format=UIGraphicsImageRendererFormat();format.scale=1
        var rendered:[Data]=[]
        var images:[UIImage]=[]
        let variants=[("animated_robot","Wave",0.0),("animated_robot","Wave",0.65),("animated_fox","Run",0.0),("animated_fox","Run",0.5)]
            for variant in variants {
                let node=try SpatialAssets.load(variant.0)
                try SpatialRig.previewPose(node,clip:variant.1,fraction:variant.2)
                let scene=SCNScene();scene.background.contents=UIColor(white:0.06,alpha:1);scene.rootNode.addChildNode(node)
                let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.fieldOfView=50
                let robot=variant.0 == "animated_robot"
                camera.position=robot ? SCNVector3(2.2,1.5,3.2) : SCNVector3(0.9,0.65,1.1)
                camera.look(at:robot ? SCNVector3(0,0.85,0) : SCNVector3(0,0.22,0));scene.rootNode.addChildNode(camera)
                let sun=SCNNode();sun.light=SCNLight();sun.light?.type = .directional;sun.light?.intensity=1000;sun.eulerAngles=SCNVector3(-0.7,-0.4,0);scene.rootNode.addChildNode(sun)
                let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=550;scene.rootNode.addChildNode(ambient)
                let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
                let image=renderer.snapshot(atTime:0,with:CGSize(width:500,height:400),antialiasingMode:.multisampling4X)
                rendered.append(try XCTUnwrap(image.pngData()))
                images.append(image)
            }
        let atlas=UIGraphicsImageRenderer(size:CGSize(width:1000,height:850),format:format).image { context in
            UIColor(white:0.06,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:1000,height:850))
            for (index,image) in images.enumerated() {
                let variant=variants[index],x=CGFloat(index%2)*500,y=CGFloat(index/2)*425
                image.draw(at:CGPoint(x:x,y:y))
                ((variant.0+" · "+variant.1+" · "+String(variant.2)) as NSString).draw(at:CGPoint(x:x+10,y:y+400),withAttributes:[.font:UIFont.systemFont(ofSize:16),.foregroundColor:UIColor.white])
            }
        }
        XCTAssertNotEqual(rendered[0],rendered[1]);XCTAssertNotEqual(rendered[2],rendered[3])
        let attachment=XCTAttachment(image:atlas);attachment.name="Animated-characters-rev26";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testPalmRecallOnlyReframesOffscreenWindowOnceUntilHandCloses() {
        var recall=SpatialPalmRecall()
        for tick in 0...9 { XCTAssertNil(recall.update(open:true,target:"panel",overInterface:false,time:Double(tick)/10)) }
        XCTAssertEqual(recall.update(open:true,target:"panel",overInterface:false,time:1.01),"panel")
        XCTAssertNil(recall.update(open:true,target:nil,overInterface:false,time:1.1))
        XCTAssertTrue(recall.hasFired)
        XCTAssertNil(recall.update(open:false,target:nil,overInterface:false,time:1.2))
        XCTAssertFalse(recall.hasFired)
        for tick in 0...15 { XCTAssertNil(recall.update(open:true,target:"panel",overInterface:true,time:2+Double(tick)/10)) }
        XCTAssertEqual(recall.progress,0)
        XCTAssertNil(recall.update(open:true,target:"panel",overInterface:false,time:5))
        XCTAssertNil(recall.update(open:true,target:"panel",overInterface:false,time:6)) // lost hand resets dwell
    }
    func testPalmResizeCanUseApparentHandSizeWithoutLiDAR() throws {
        var calibration=SpatialPalmCalibration()
        XCTAssertEqual(try XCTUnwrap(calibration.estimate(target:"panel",span:0.2,measured:nil)),0.5,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(calibration.estimate(target:"panel",span:0.4,measured:nil)),0.25,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(calibration.estimate(target:"panel",span:0.1,measured:nil)),1,accuracy:0.001)
        XCTAssertNil(calibration.estimate(target:nil,span:0.1,measured:nil))
        XCTAssertEqual(try XCTUnwrap(calibration.estimate(target:"desktop",span:0.15,measured:0.7)),0.7,accuracy:0.001)
    }
    func testNewMapKeepsBackupAndRestoringInvalidMapCannotReplaceCurrent() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent("home.json")
        let room=SpatialRoom(id:UUID(),name:"Quarto",origin:SpatialArchive.values(matrix_identity_float4x4))
        let archive=SpatialArchive(world:UUID(),rooms:[room],objects:[],panel:nil,map:Data([1,2,3]),saved:Date())
        try archive.write(to:file)
        try SpatialArchive.activate(nil,at:file)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        let backup=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first)
        XCTAssertEqual(try SpatialArchive.load(from:backup)?.world,archive.world)
        try SpatialArchive.activate(backup,at:file)
        XCTAssertEqual(try SpatialArchive.load(from:file)?.world,archive.world)
        let bad=dir.appendingPathComponent("bad.json");try Data("{}".utf8).write(to:bad)
        XCTAssertThrowsError(try SpatialArchive.activate(bad,at:file))
        XCTAssertEqual(try SpatialArchive.load(from:file)?.world,archive.world)
    }
    @MainActor func testCharactersHaveIndependentSkeletonsAndRealAnimationTracks() throws {
        for id in SpatialRig.identifiers {
            let a=try SpatialAssets.load(id),b=try SpatialAssets.load(id)
            let jointA=try XCTUnwrap(a.childNode(withName:"rig-joint-0",recursively:true))
            let jointB=try XCTUnwrap(b.childNode(withName:"rig-joint-0",recursively:true))
            XCTAssertFalse(jointA === jointB)
            var skins=0
            a.enumerateChildNodes { node,_ in
                if let skinner=node.skinner {
                    skins+=1;XCTAssertGreaterThan(skinner.bones.count,20);XCTAssertNotNil(skinner.skeleton)
                    XCTAssertEqual(skinner.boneIndices.bytesPerComponent,2)
                    XCTAssertEqual(skinner.boneWeights.vectorCount,skinner.boneIndices.vectorCount)
                }
            }
            XCTAssertGreaterThan(skins,0)
            XCTAssertNotNil(jointA.animation(forKey:"rig-motion"))
            XCTAssertTrue(SpatialRig.play(a,clip:id == "animated_robot" ? "Wave" : "Run"))
            XCTAssertFalse(SpatialRig.play(a,clip:"nonexistent"))
        }
        XCTAssertEqual(WallARCommand.parse("coloque um robô aqui",inStudio:true),.model("animated_robot"))
        XCTAssertEqual(WallARCommand.parse("robô dance",inStudio:true),.character("Dance"))
        XCTAssertNil(WallARCommand.parse("não socar parede",inStudio:true))
    }
    @MainActor func testResumeRetainsMapAndRequiresRepeatedSurfaceEvidence() {
        let controller=WallARController()
        XCTAssertTrue(controller.sessionShouldAttemptRelocalization(controller.view.session))
        var proof=SpatialSupportProof()
        proof.observe(matches:0,conflicts:0);XCTAssertFalse(proof.confirmed)
        proof.observe(matches:3,conflicts:0);XCTAssertFalse(proof.confirmed)
        proof.observe(matches:3,conflicts:0);XCTAssertTrue(proof.confirmed)
        proof.observe(matches:0,conflicts:0);XCTAssertTrue(proof.confirmed)
        proof.observe(matches:1,conflicts:2);XCTAssertFalse(proof.confirmed)
        proof=SpatialSupportProof();proof.observe(matches:4,conflicts:0)
        XCTAssertFalse(proof.confirmed)
        controller.stop()
    }
    @MainActor func testDesktopWindowClicksAndMovesWithNoHandDepth() throws {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:600,height:900));view.scene=SCNScene()
        let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0,0,1)
        camera.camera?.zNear=0.01;camera.camera?.zFar=10;camera.camera?.fieldOfView=60
        view.scene.rootNode.addChildNode(camera);view.pointOfView=camera
        let desktop=SpatialDesktop(view:view);desktop.preview()
        var jobs:[[String:Any]]=[];desktop.send={jobs.append($0)}
        for tick in 0...23 {
            let sample=SpatialHandSample(point:CGPoint(x:300,y:450),ratio:1,menuPose:false,pointing:true,time:Double(tick)*0.1)
            XCTAssertTrue(desktop.hand(sample))
        }
        XCTAssertEqual(jobs.filter{$0["action"] as? String == "click"}.count,1)
        func hand(_ ratio:Double,_ time:Double,_ y:Double) {
            _=desktop.hand(SpatialHandSample(point:CGPoint(x:300,y:y),ratio:ratio,menuPose:false,pointing:false,time:time))
        }
        hand(1,2.4,450);hand(0.1,2.5,450);hand(0.1,2.7,450);hand(0.1,2.8,410)
        XCTAssertGreaterThan(try XCTUnwrap(desktop.previewPosition).y,0.01)
        hand(1,2.9,410)
        XCTAssertFalse(desktop.isDragging)
        XCTAssertNotNil(desktop.snapshot())
        desktop.close(recordChange:false)
    }
    func testPointingWithoutThumbOrDepthCanDwellAndLossStillCancelsPinch() {
        var gesture=SpatialGesture(),clicks=0
        for tick in 0...28 {
            let events=gesture.update(ratio:.nan,pointing:true,target:"desktop",time:Double(tick)*0.1)
            clicks += events.filter { $0 == .click("desktop") }.count
        }
        XCTAssertEqual(clicks,1)
        _=gesture.update(ratio:1,pointing:false,target:nil,time:2.9)
        XCTAssertTrue(gesture.update(ratio:0.1,pointing:false,target:"desktop",time:3).isEmpty)
        XCTAssertEqual(gesture.update(ratio:0.1,pointing:false,target:"desktop",time:3.2),[.press("desktop")])
        XCTAssertTrue(gesture.update(ratio:.nan,pointing:false,target:nil,time:3.3).isEmpty)
        XCTAssertEqual(gesture.update(ratio:.nan,pointing:false,target:nil,time:3.6),[.cancel])
    }
    func testSpatialArchiveRoundTripRejectsDuplicateIDsAndInvalidTransforms() throws {
        let room=SpatialRoom(id:UUID(),name:"Quarto",origin:SpatialArchive.values(matrix_identity_float4x4))
        var pose=matrix_identity_float4x4;pose.columns.3=SIMD4(1,0,-2,1)
        let record=SpatialObjectRecord(id:UUID(),model:"demo_box",room:room.id,anchor:UUID(),localTransform:SpatialArchive.values(pose),scale:1,updated:Date())
        var archive=SpatialArchive(world:UUID(),rooms:[room],objects:[record],panel:nil,map:Data([1,2,3]),saved:Date())
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("map.json")
        try archive.write(to:file)
        let restored=try XCTUnwrap(SpatialArchive.load(from:file))
        XCTAssertEqual(restored.objects,[record]);XCTAssertEqual(restored.rooms,[room]);XCTAssertEqual(restored.world,archive.world)
        archive.objects.append(record)
        XCTAssertThrowsError(try archive.write(to:file))
        XCTAssertEqual(try SpatialArchive.load(from:file)?.objects.count,1)
        archive.objects=[record];archive.objects[0].localTransform[0] = .nan
        XCTAssertThrowsError(try archive.validate())
        XCTAssertNil(SpatialArchive.matrix([1,2]))
    }
    func testPalmScaleNeedsStableSelectionAndResetsAfterLostHand() throws {
        var gesture=SpatialPalmScale()
        for i in 0...5 { XCTAssertNil(gesture.update(target:nil,depth:0.4,time:Double(i)*0.1)) }
        for i in 0...5 { XCTAssertNil(gesture.update(target:"box",depth:0.4,time:1+Double(i)*0.1)) }
        var factors:[Float]=[]
        for i in 1...6 { if let f=gesture.update(target:"box",depth:0.4+Double(i)*0.02,time:1.5+Double(i)*0.1) { factors.append(f) } }
        XCTAssertFalse(factors.isEmpty);XCTAssertTrue(factors.allSatisfy { $0<1 })
        XCTAssertNil(gesture.update(target:"box",depth:0.2,time:4))
        XCTAssertNil(gesture.update(target:"box",depth:nil,time:4.1))
        XCTAssertEqual(WallARCommand.parse("puxe a tela do computador",inStudio:true),.desktop)
        XCTAssertEqual(WallARCommand.parse("coloque um personagem aqui",inStudio:true),.model("animated_robot"))
        XCTAssertNil(WallARCommand.parse("não coloque uma cadeira",inStudio:true))
    }
    @MainActor func testMetricDemoModelsHaveFloorOriginsAndRealHeights() throws {
        for (demo,height) in [(SpatialDemo.human,Float(1.7)),(.box,0.30),(.chair,0.90),(.table,0.75),(.panel,0.36)] {
            let node=try demo.make(),bounds=node.boundingBox
            XCTAssertEqual(bounds.min.y,0,accuracy:0.001,demo.rawValue)
            XCTAssertEqual(bounds.max.y-bounds.min.y,height,accuracy:0.001,demo.rawValue)
        }
    }
    func testPortraitPanelIgnoresCameraRollAndFitsScreen() throws {
        let viewport=CGSize(width:390,height:760)
        let f:Float=1/tan(.pi/6),aspect=Float(viewport.width/viewport.height)
        let projection=simd_float4x4(SIMD4(f/aspect,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,-1.002,-1),SIMD4(0,0,-0.02002,0))
        // Camera's sensor coordinates can be rolled 90 degrees; world up cannot.
        for roll in [0,Float.pi/2,-Float.pi/2,0.15] as [Float] {
            let camera=simd_float4x4(simd_quatf(angle:roll,axis:SIMD3(0,0,1)))
            let panel=try XCTUnwrap(SpatialPanelGeometry.upright(camera:camera,distance:0.9))
            XCTAssertEqual(panel.columns.1,SIMD4<Float>(0,1,0,0))
            XCTAssertEqual(panel.columns.3.z,-0.9,accuracy:0.001)
        }
        let panel=try XCTUnwrap(SpatialPanelGeometry.upright(camera:matrix_identity_float4x4,distance:0.9))
        let scale=try XCTUnwrap(SpatialPanelGeometry.fittedScale(transform:panel,view:matrix_identity_float4x4,projection:projection,viewport:viewport))
        let bounds=try XCTUnwrap(SpatialPanelGeometry.projectedBounds(transform:panel,scale:scale,view:matrix_identity_float4x4,projection:projection,viewport:viewport))
        XCTAssertGreaterThanOrEqual(bounds.minX,viewport.width*0.12)
        XCTAssertLessThanOrEqual(bounds.maxX,viewport.width*0.88)
        XCTAssertGreaterThan(bounds.minY,76)
        XCTAssertLessThan(bounds.maxY,viewport.height-136)
        let ceiling=simd_float4x4(simd_quatf(angle:Float.pi/2,axis:SIMD3(1,0,0)))
        let overhead=try XCTUnwrap(SpatialPanelGeometry.upright(camera:ceiling,distance:0.9))
        XCTAssertEqual(overhead.columns.3.y,0.9,accuracy:0.001)
        XCTAssertNotNil(SpatialPanelGeometry.fittedScale(transform:overhead,view:simd_inverse(ceiling),projection:projection,viewport:viewport))
    }
    func testHandWithoutWristStillMeasuresPinchAndMissingThumbCannotClick() throws {
        var joints=[CGPoint?](repeating:nil,count:21)
        joints[5]=CGPoint(x:0.35,y:0.6);joints[17]=CGPoint(x:0.65,y:0.6)
        joints[8]=CGPoint(x:0.45,y:0.3);joints[4]=CGPoint(x:0.48,y:0.3)
        XCTAssertEqual(try XCTUnwrap(SpatialHandMath.pinchRatio(joints,size:CGSize(width:1000,height:1000))),0.1,accuracy:0.001)
        joints[4]=nil;XCTAssertNil(SpatialHandMath.pinchRatio(joints,size:CGSize(width:1000,height:1000)))
        var gate=SpatialGesture()
        for i in 0..<10 { XCTAssertTrue(gate.update(ratio:.nan,pointing:true,target:"play",time:Double(i)).isEmpty) }
        XCTAssertEqual(SpatialHandMath.rawPoint(CGPoint(x:0.2,y:0.3),orientation:.right),CGPoint(x:0.7,y:0.8))
        let up=SpatialHandMath.rawPoint(CGPoint(x:0.2,y:0.3),orientation:.up)
        XCTAssertEqual(up.x,0.2,accuracy:0.0001);XCTAssertEqual(up.y,0.7,accuracy:0.0001)
    }
    func testPanelRaySelectionRemainsIndependentOfDepthMeshes() throws {
        var panel=matrix_identity_float4x4;panel.columns.3=SIMD4(0,0,-0.9,1)
        for i in 0..<3 { panel[i] *= 0.5 }
        let center=try XCTUnwrap(SpatialPanelGeometry.localHit(origin:.zero,direction:SIMD3(0,0,-1),transform:panel))
        XCTAssertEqual(center.x,0,accuracy:0.001);XCTAssertEqual(center.y,0,accuracy:0.001)
        let card=try XCTUnwrap(SpatialPanelGeometry.localHit(origin:.zero,direction:SIMD3(0.08,0.0675,-0.896),transform:panel))
        XCTAssertEqual(card.x,0.16,accuracy:0.001);XCTAssertEqual(card.y,0.135,accuracy:0.001)
        XCTAssertNil(SpatialPanelGeometry.localHit(origin:.zero,direction:SIMD3(1,0,-1),transform:panel))
        XCTAssertNil(SpatialPanelGeometry.localHit(origin:.zero,direction:SIMD3(0,0,1),transform:panel))
        XCTAssertNil(SpatialPanelGeometry.localHit(origin:.zero,direction:SIMD3(1,0,0),transform:panel))
    }
    @MainActor func testInteractiveScenariosHaveWorkingActions() throws {
        for theme in [SpatialTheme.garage,.lounge,.aquarium] {
            let view=ARSCNView(frame:.zero);view.scene=SCNScene();let world=SpatialWorld(view:view);try world.preview(theme)
            if theme == .garage {
                let car=try XCTUnwrap(view.scene.rootNode.childNode(withName:"movingCar",recursively:true))
                world.interact();XCTAssertNotNil(car.action(forKey:"drive"));world.interact();XCTAssertNil(car.action(forKey:"drive"))
            } else if theme == .lounge {
                let light=try XCTUnwrap(view.scene.rootNode.childNode(withName:"roomLight",recursively:true))
                world.interact();XCTAssertTrue(light.isHidden);world.interact();XCTAssertFalse(light.isHidden)
            } else {
                let fish=try XCTUnwrap(view.scene.rootNode.childNode(withName:"fishOrbit",recursively:true))
                world.interact();XCTAssertTrue(fish.isPaused);world.interact();XCTAssertFalse(fish.isPaused)
            }
            world.stop()
        }
    }
    @MainActor func testTwentyAdditionalModelsRenderActualGeometry() throws {
        XCTAssertEqual(SpatialAssets.catalog.filter { !$0.id.hasPrefix("demo_") && !$0.id.hasPrefix("animated_") }.count,22)
        XCTAssertEqual(Set(SpatialAssets.catalog.map(\.id)).count,SpatialAssets.catalog.count)
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let atlas=UIGraphicsImageRenderer(size:CGSize(width:1400,height:1750)).image { ctx in
            UIColor.black.setFill();ctx.fill(CGRect(x:0,y:0,width:1400,height:1750))
            for (i,item) in SpatialAssets.catalog.filter({ !$0.id.hasPrefix("demo_") && !$0.id.hasPrefix("animated_") }).enumerated() {
                do {
                    let scene=SCNScene();scene.background.contents=UIColor(white:0.08,alpha:1)
                    let model=try SpatialAssets.load(item.id);scene.rootNode.addChildNode(model)
                    var triangles=0;model.enumerateChildNodes { node,_ in triangles += node.geometry?.elements.reduce(0,{$0+$1.primitiveCount}) ?? 0 }
                    XCTAssertGreaterThan(triangles,500,item.id)
                    let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(1.2,0.9,1.5);camera.look(at:SCNVector3(0,0.4,0))
                    scene.rootNode.addChildNode(camera)
                    let light=SCNNode();light.light=SCNLight();light.light?.type = .directional;light.light?.intensity=900;light.eulerAngles=SCNVector3(-0.7,-0.4,0);scene.rootNode.addChildNode(light)
                    let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=450;scene.rootNode.addChildNode(ambient)
                    let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
                    let image=renderer.snapshot(atTime:0,with:CGSize(width:280,height:300),antialiasingMode:.multisampling4X)
                    XCTAssertNotNil(image.cgImage,item.id)
                    let origin=CGPoint(x:CGFloat((i%5)*280),y:CGFloat((i/5)*350))
                    image.draw(at:origin)
                    (item.title as NSString).draw(in:CGRect(x:origin.x+8,y:origin.y+302,width:264,height:40),withAttributes:[.font:UIFont.systemFont(ofSize:18),.foregroundColor:UIColor.white])
                    renderer.scene=nil;SpatialAssets.clear()
                } catch { XCTFail("Model \(item.id): \(error)") }
            }
        }
        let attachment=XCTAttachment(image:atlas);attachment.name="Spatial-22-models-catalog";attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor func testPortraitPerspectivePanelPreviewAndPagination() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let viewport=CGSize(width:390,height:760)
        let view=ARSCNView(frame:CGRect(origin:.zero,size:viewport));view.scene=SCNScene();view.scene.background.contents=UIColor(white:0.12,alpha:1)
        let panel=SpatialPanel(view:view);panel.preview(.dashboard);panel.setTracking(true)
        let node=try XCTUnwrap(view.scene.rootNode.childNodes.first)
        let f:Float=1/tan(.pi/6),aspect=Float(viewport.width/viewport.height)
        let projection=simd_float4x4(SIMD4(f/aspect,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,-1.002,-1),SIMD4(0,0,-0.02002,0))
        let pose=try XCTUnwrap(SpatialPanelGeometry.upright(camera:matrix_identity_float4x4,distance:0.9))
        node.simdTransform=pose;node.simdScale=SIMD3(repeating:try XCTUnwrap(SpatialPanelGeometry.fittedScale(transform:pose,view:matrix_identity_float4x4,projection:projection,viewport:viewport)))
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.projectionTransform=SCNMatrix4(projection);view.scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:viewport,antialiasingMode:.multisampling4X)
        let attachment=XCTAttachment(image:image);attachment.name="Spatial-portrait-real-perspective";attachment.lifetime = .keepAlways;add(attachment)
        var job:[String:Any]=[:];panel.onSpotify={job=$0}
        panel.interpret("mostrar mais cartões")
        let first=try XCTUnwrap(job["items"] as? [[String:String]])
        XCTAssertEqual(first.first?["title"],"Spotify")
        let next=try XCTUnwrap(first.firstIndex(where:{$0["title"]=="Mais cartões"}))
        try panel.receive(JSONSerialization.data(withJSONObject:["requestId":job["requestId"]!,"navigation":["operation":"activate","slot":next]]))
        panel.interpret("mostrar esta página")
        let second=try XCTUnwrap(job["items"] as? [[String:String]])
        XCTAssertEqual(second.first?["title"],"Controles do iPhone")
        panel.close()
    }
    @MainActor func testDirectoryFindsModulesAndActionsOnLaterPages() throws {
        let view=ARSCNView(frame:.zero);view.scene=SCNScene()
        let panel=SpatialPanel(view:view)
        XCTAssertEqual(panel.directory("").count,SpatialModule.navigationCases.count-1)
        XCTAssertEqual(panel.directory("desligar dados").first?.page,1)
        XCTAssertEqual(panel.directory("flauta").first?.module,.instruments)
        XCTAssertEqual(panel.directory("criar lembrete").first?.module,.notebook)
        XCTAssertEqual(panel.directory("madeira").first?.module,.scenes)
        XCTAssertTrue(panel.directory("bluetooth").count>=2)
        XCTAssertTrue(panel.directory("xyz123").isEmpty)
        XCTAssertEqual(SpatialModule.opening("abrir sistema e foco"),.system)
    }
    @MainActor func testUnifiedSceneDirectoryRetainsPaintAndModelsWithoutDuplicateModules() throws {
        let view=ARSCNView(frame:CGRect(x:0,y:0,width:390,height:760));view.scene=SCNScene()
        let panel=SpatialPanel(view:view)
        let entries=panel.directory("")
        XCTAssertEqual(entries.filter{$0.module == .scenes}.count,1)
        XCTAssertFalse(entries.contains{$0.module == .walls})
        XCTAssertEqual(SpatialModule.walls.canonical,.scenes)
        for term in ["madeira","Marcar parede","Portal na parede","Raposa","Bosque"] {
            XCTAssertTrue(panel.directory(term).contains{$0.module == .scenes},term)
        }
        for phrase in ["abrir cenário 3d","abrir medir e pintar","abrir ambientes"] {
            XCTAssertEqual(SpatialModule.opening(phrase),.scenes,phrase)
        }
    }
    @MainActor func testCloudCatalogRejectsPathsOversizedGeometryAndInvalidHashes() {
        let valid:[String:Any]=["id":"test","title":"Teste","triangles":12,"files":[["file":"Spatial_test.mesh","bytes":200,"sha256":String(repeating:"a",count:64)]]]
        XCTAssertTrue(SpatialCloudLibrary.valid(valid))
        var bad=valid;bad["triangles"]=900000;XCTAssertFalse(SpatialCloudLibrary.valid(bad))
        bad=valid;bad["files"]=[["file":"../Spatial_test.mesh","bytes":200,"sha256":String(repeating:"a",count:64)]];XCTAssertFalse(SpatialCloudLibrary.valid(bad))
        bad=valid;bad["files"]=[["file":"Spatial_test.mesh","bytes":200,"sha256":"invalid"]];XCTAssertFalse(SpatialCloudLibrary.valid(bad))
        bad=valid;bad["files"]=[["file":"Spatial_test.mesh","bytes":100*1024*1024,"sha256":String(repeating:"a",count:64)]];XCTAssertFalse(SpatialCloudLibrary.valid(bad))
    }
    func testSpatialAINavigationKeepsOrdinaryToolsOutsideTheInterpreter() {
        for phrase in ["me leva para os controles da casa","voltar às playlists","quero ver os módulos","seleciona a segunda faixa","toca essa","fecha esse painel"] {
            XCTAssertTrue(WallARCommand.needsInterpretation(phrase),phrase)
        }
        for phrase in ["não abre o Spotify","se eu abrir o painel","ligue a luz","brilho do iPhone em 30%","o que estou vendo","qual a previsão do tempo"] {
            XCTAssertFalse(WallARCommand.needsInterpretation(phrase),phrase)
        }
    }
    @MainActor func testSpatialAIExecutesOnlyCurrentCardsAndRejectsStaleResults() throws {
        let view=ARSCNView(frame:.zero);view.scene=SCNScene()
        let panel=SpatialPanel(view:view);panel.preview(.phone);panel.setTracking(true)
        var job:[String:Any]=[:];var commands:[String]=[]
        panel.onSpotify={job=$0};panel.onAction={if case .command(let text)=$0 { commands.append(text) }}
        func respond(_ slot:Int) throws {
            panel.receive(try JSONSerialization.data(withJSONObject:["requestId":job["requestId"]!,"navigation":["operation":"activate","slot":slot]]))
        }
        panel.interpret("abre a lanterna");try respond(0)
        XCTAssertEqual(commands,["ligue a lanterna do iPhone"])
        panel.interpret("abre a lanterna");try respond(900)
        XCTAssertEqual(commands.count,1)
        panel.interpret("abre a lanterna");panel.open(.home,tracking:true);try respond(0)
        XCTAssertEqual(commands.count,1)
        panel.close()
    }
    func testPointingRequiresTwoContinuousSecondsAndFiresOnce() {
        var gate=SpatialGesture()
        func event(_ tick:Int,_ target:String="play",_ pointing:Bool=true)->[SpatialGesture.Event] {
            gate.update(ratio:1,pointing:pointing,target:target,time:Double(tick)/10)
        }
        for tick in 0...20 { XCTAssertEqual(event(tick),[]) }
        XCTAssertEqual(event(21),[.click("play")])
        for tick in 22...51 { XCTAssertEqual(event(tick),[]) }
        XCTAssertEqual(event(52,"play",false),[])
        for tick in 53...70 { XCTAssertEqual(event(tick),[]) }
        for tick in 71...91 { XCTAssertEqual(event(tick,"next"),[]) }
        XCTAssertEqual(event(92,"next"),[.click("next")])
        XCTAssertEqual(event(130),[])
    }
    @MainActor func testMediaModulesAndPlaylistPlayback() throws {
        XCTAssertEqual(SpatialModule.opening("abre o YouTube"),.youtube)
        XCTAssertEqual(SpatialModule.opening("abrir navegador"),.browser)
        XCTAssertEqual(SpatialModule.opening("abrir comandos"),.commands)
        let view=ARSCNView(frame:.zero);view.scene=SCNScene()
        let panel=SpatialPanel(view:view);panel.preview(.spotify);panel.setTracking(true)
        var job:[String:Any]=[:];panel.onSpotify={job=$0}
        func reply(_ payload:[String:Any]) throws {
            var result=payload;result["requestId"]=try XCTUnwrap(job["requestId"])
            panel.receive(try JSONSerialization.data(withJSONObject:result))
        }
        func choose(_ title:String) throws {
            panel.interpret(title)
            let rows=try XCTUnwrap(job["items"] as? [[String:String]])
            let slot=try XCTUnwrap(rows.firstIndex { $0["title"]==title })
            try reply(["navigation":["operation":"activate","slot":slot]])
        }
        panel.request("library")
        try reply(["playlists":[["id":"mix","name":"Meu mix"]]])
        try choose("Meu mix")
        XCTAssertEqual(job["action"] as? String,"tracks")
        try reply(["playlistId":"mix","tracks":[["id":"song","name":"Faixa","artist":"Artista"]]])
        try choose("Tocar playlist")
        XCTAssertEqual(job["action"] as? String,"play")
        XCTAssertEqual(job["playlistId"] as? String,"mix")
        try reply([:])
        try choose("Faixa · Artista")
        try choose("Play: Faixa · Artista")
        XCTAssertEqual(job["action"] as? String,"play_track")
        XCTAssertEqual(job["trackId"] as? String,"song")
        panel.close()
    }
    func testPinchDragsOnlyAndLostTrackingCancels() {
        var gate=SpatialGesture()
        func event(_ ratio:Double,_ tick:Int,_ target:String?)->[SpatialGesture.Event] {
            gate.update(ratio:ratio,pointing:false,target:target,time:Double(tick)/10)
        }
        XCTAssertTrue(event(0.12,0,"play").isEmpty)
        XCTAssertTrue(event(0.12,1,"play").isEmpty)
        XCTAssertEqual(event(0.12,2,"play"),[.press("play")])
        XCTAssertEqual(event(0.15,3,nil),[.drag("play")])
        XCTAssertEqual(event(1,4,"other"),[.release])
        for tick in 5...30 { XCTAssertTrue(event(1,tick,"play").isEmpty) }
        XCTAssertTrue(event(0.12,31,"play").isEmpty)
        XCTAssertEqual(event(0.12,33,"play"),[.press("play")])
        XCTAssertTrue(event(.nan,34,nil).isEmpty) // Pause briefly; never drag stale coordinates.
        XCTAssertEqual(event(.nan,37,nil),[.cancel])
    }
    func testMenuSwipeNeedsDirectionAndRelease() {
        var swipe=SpatialPageSwipe()
        func update(_ x:Double,_ y:Double,_ t:Double)->Int? { swipe.update(point:CGPoint(x:x,y:y),time:t) }
        XCTAssertNil(update(0.6,0.5,0)); XCTAssertNil(update(0.52,0.52,0.1))
        XCTAssertEqual(update(0.38,0.53,0.2),1); XCTAssertNil(update(0.12,0.53,0.3))
        XCTAssertNil(swipe.update(point:nil,time:0.4)); XCTAssertNil(update(0.2,0.5,0.5))
        XCTAssertEqual(update(0.4,0.51,0.75),-1)
        XCTAssertNil(swipe.update(point:nil,time:0.8)); XCTAssertNil(update(0.5,0.2,1))
        XCTAssertNil(update(0.7,0.6,1.2))
    }
    func testOpenPalmIsFreeAndCurledFingersAllowPointing() {
        var joints=[CGPoint?](repeating:nil,count:21)
        for base in [5,9,13,17] {
            joints[base]=CGPoint(x:base,y:60)
            joints[base+1]=CGPoint(x:base,y:40)
            joints[base+3]=CGPoint(x:base,y:10)
        }
        XCTAssertFalse(SpatialHandMath.pointing(joints))
        for base in [9,13,17] { joints[base+3]=CGPoint(x:base,y:55) }
        XCTAssertTrue(SpatialHandMath.pointing(joints))
    }
    @MainActor func testSpatialDashboardRendersRealModuleCards() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view=ARSCNView(frame:.zero);view.scene=SCNScene();view.scene.background.contents=UIColor(white:0.07,alpha:1)
        let panel=SpatialPanel(view:view)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=0.48
        camera.camera?.zNear=0.01;camera.camera?.zFar=10
        camera.position=SCNVector3(0,0,1);view.scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
        for module in [SpatialModule.dashboard,.scenes,.home,.phone] {
            panel.preview(module)
            let screenshot=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:900),antialiasingMode:.multisampling4X)
            let attachment=XCTAttachment(image:screenshot);attachment.name="Spatial-panel-\(module.rawValue)";attachment.lifetime = .keepAlways;add(attachment)
            XCTAssertNotNil(screenshot.cgImage)
            let cg=try XCTUnwrap(screenshot.cgImage)
            // Preserve glyphs when sampling: a 64px thumbnail erased thin lettering.
            var pixels=[UInt8](repeating:0,count:256*256*4)
            let context=try XCTUnwrap(CGContext(data:&pixels,width:256,height:256,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in:CGRect(x:0,y:0,width:256,height:256))
            XCTAssertGreaterThan(stride(from:0,to:pixels.count,by:4).filter { max(pixels[$0],pixels[$0+1],pixels[$0+2])>100 }.count,100,"Panel must contain visible controls, not a blank snapshot")
        }
        panel.close()
    }
    func testGeneralSpatialModulesAndOrdinaryCommandsRemainSeparate() {
        for (phrase,target) in [("Jarvis, abrir painel",SpatialModule.dashboard),("abrir módulo Spotify",.spotify),("abrir controles",.phone),("mostrar painel da casa",.home),("abrir módulo câmera",.camera),("abrir módulo criação",.creation),("abrir módulo cenários",.scenes),("abrir módulo instrumentos",.instruments),("abrir módulo libras",.libras),("abrir módulo tradução",.translation),("abrir painel meu dia",.personal)] {
            XCTAssertEqual(WallARCommand.parse(phrase,inStudio:false),.panel(target),phrase)
        }
        XCTAssertEqual(WallARCommand.parse("abrir Spotify",inStudio:true),.panel(.spotify))
        XCTAssertNil(WallARCommand.parse("abrir harpa",inStudio:false))
        XCTAssertNil(WallARCommand.parse("não abrir painel",inStudio:true))
        XCTAssertNil(WallARCommand.parse("brilho da lâmpada em 30%",inStudio:true))
        XCTAssertNil(WallARCommand.parse("brilho do iPhone em 30%",inStudio:true))
    }
    func testMeasuredWallSubtractsDoorAndCupboardEvenAcrossLargeTriangles() {
        let wall: [SIMD2<Float>]=[.init(0,0),.init(4,0),.init(4,3),.init(0,3)]
        let door=WallOpening(.init(0.5,0),.init(1.5,2),margin:0)
        let cupboard=WallOpening(.init(2,0),.init(3.5,2.5),margin:0)
        let triangles=MeasuredWall.triangles(wall,excluding:[door,cupboard])
        XCTAssertEqual(triangles.reduce(Float(0)) { $0+MeasuredWall.area($1) },6.25,accuracy:0.0001)
        for t in triangles {
            let center=(t[0]+t[1]+t[2])/3
            XCTAssertFalse(door.contains(center));XCTAssertFalse(cupboard.contains(center))
        }
        // Overlapping holes must not subtract the overlap twice.
        let second=WallOpening(.init(1,0),.init(2,2),margin:0)
        let overlap=MeasuredWall.triangles(wall,excluding:[door,second])
        XCTAssertEqual(overlap.reduce(Float(0)) { $0+MeasuredWall.area($1) },9,accuracy:0.0001)
        XCTAssertTrue(MeasuredWall.triangles(wall,excluding:[WallOpening(.init(-1,-1),.init(5,4),margin:0)]).isEmpty)
    }
    func testMeasuredContoursRejectCrossingAndKeepConcaveWalls() {
        XCTAssertFalse(MeasuredWall.valid([.init(0,0),.init(2,2),.init(0,2),.init(2,0)]))
        XCTAssertFalse(MeasuredWall.valid([.init(0,0),.init(.nan,1),.init(1,0)]))
        XCTAssertFalse(MeasuredWall.valid([.init(0,0),.init(0.01,0),.init(0,0.01)]))
        let outline: [SIMD2<Float>]=[.init(0,0),.init(3,0),.init(3,1),.init(1,1),.init(1,3),.init(0,3)]
        XCTAssertTrue(MeasuredWall.valid(outline))
        XCTAssertTrue(MeasuredWall.contains(.init(0.5,2),polygon:outline))
        XCTAssertFalse(MeasuredWall.contains(.init(2,2),polygon:outline))
        let divided=WallDepthEvidence.subdivide(MeasuredWall.triangles(outline,excluding:[]))
        XCTAssertLessThan(divided.count,18000)
        XCTAssertEqual(divided.reduce(Float(0)) { $0+MeasuredWall.area($1) },5,accuracy:0.001)
    }
    func testDepthRequiresRepeatedHighConfidenceAndImmediatelyRejectsFurniture() {
        var evidence=WallDepthEvidence()
        XCTAssertTrue(evidence.observe([.wall,.unknown,.obstacle,.outside]).isEmpty)
        XCTAssertEqual(evidence.observe([.wall,.wall,.wall,.outside]),[0])
        XCTAssertEqual(evidence.observe([.obstacle,.wall,.unknown,.outside]),[1])
        XCTAssertEqual(evidence.observe([.wall,.outside,.unknown,.outside]),[1])
        XCTAssertEqual(evidence.observe([.wall,.unknown,.unknown,.outside]),[0])
        if case .obstacle = WallDepthEvidence.classify(expected:2,measured:1.4,confidence:2) {} else { XCTFail("Furniture must reject paint") }
        if case .unknown = WallDepthEvidence.classify(expected:2,measured:3,confidence:2) {} else { XCTFail("An opening is not a wall") }
        if case .unknown = WallDepthEvidence.classify(expected:2,measured:2,confidence:1) {} else { XCTFail("Low confidence must not authorize paint") }
        if case .wall = WallDepthEvidence.classify(expected:2,measured:2.02,confidence:2) {} else { XCTFail("Measured coplanar surface") }
    }
    func testSpatialVoiceCommandsAndNegations() {
        XCTAssertEqual(WallARCommand.parse("Oi Jarvis, cenário floresta",inStudio:false),.theme(.forest))
        XCTAssertEqual(WallARCommand.parse("bosque noturno",inStudio:true),.theme(.enchanted))
        XCTAssertEqual(WallARCommand.parse("coloca o rádio",inStudio:true),.theme(.studio))
        XCTAssertEqual(WallARCommand.parse("marca a parede",inStudio:true),.measure)
        XCTAssertEqual(WallARCommand.parse("adicionar ponto",inStudio:true),.point)
        XCTAssertEqual(WallARCommand.parse("excluir armário",inStudio:true),.opening)
        XCTAssertEqual(WallARCommand.parse("aplica o recorte",inStudio:true),.approve)
        XCTAssertNil(WallARCommand.parse("não coloca o rádio",inStudio:true))
        XCTAssertNil(WallARCommand.parse("excluir armário",inStudio:false))
    }
    @MainActor func testDownloadedSpatialModelsLoadAndRenderWithRealGeometry() throws {
        for (id,faces) in [("mossrock",5000),("fern",784),("radio",6036)] {
            let model=try SpatialAssets.load(id)
            XCTAssertEqual(model.geometry?.elements.first?.primitiveCount,faces)
            XCTAssertNotNil(model.geometry?.firstMaterial?.diffuse.contents)
            XCTAssertNotNil(model.geometry?.firstMaterial?.normal.contents)
        }
        let sound=try XCTUnwrap(Bundle.main.url(forResource:"Spatial_demo",withExtension:"wav"))
        XCTAssertGreaterThan(try AVAudioFile(forReading:sound).length,100000)
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        for theme in SpatialTheme.allCases {
            let scene=SCNScene();scene.background.contents=UIColor(white:0.09,alpha:1)
            let content=try SpatialAssets.composition(theme);scene.rootNode.addChildNode(content)
            let camera=SCNNode();camera.camera=SCNCamera();camera.position=SCNVector3(0.9,0.65,1.05)
            camera.look(at:SCNVector3(0,0.15,0));scene.rootNode.addChildNode(camera)
            let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=450;scene.rootNode.addChildNode(ambient)
            let light=SCNNode();light.light=SCNLight();light.light?.type = .directional;light.light?.intensity=600
            light.eulerAngles=SCNVector3(-0.7,-0.5,0);scene.rootNode.addChildNode(light)
            let floor=SCNNode(geometry:SCNFloor());floor.geometry?.firstMaterial?.diffuse.contents=UIColor(white:0.15,alpha:1);scene.rootNode.addChildNode(floor)
            let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
            let image=renderer.snapshot(atTime:1,with:CGSize(width:900,height:700),antialiasingMode:.multisampling4X)
            let attachment=XCTAttachment(image:image);attachment.name="Spatial-\(theme.rawValue)-downloaded-models";attachment.lifetime = .keepAlways;add(attachment)
            XCTAssertNotNil(image.cgImage)
        }
    }
    func testWallCornersJoinMeasuredCeilingAndDoNotInventMissingCeiling() {
        let outline: [SIMD2<Float>] = [.init(-0.9,0.1),.init(0.9,0.1),.init(0.9,2.8),.init(-0.9,2.8)]
        let edges = [WallEdge(normal:.init(0,-1),offset:3,ceiling:true),
                     WallEdge(normal:.init(1,0),offset:1,ceiling:false),
                     WallEdge(normal:.init(-1,0),offset:1,ceiling:false),
                     WallEdge(normal:.init(0,1),offset:0,ceiling:false)]
        let fitted = WallBoundary.fitted(outline,edges:edges)
        XCTAssertTrue(WallBoundary.touchesCeiling(fitted,edges:edges))
        XCTAssertEqual(fitted.map { $0.y }.max(),3)
        XCTAssertEqual(fitted.map { $0.y }.min(),0)
        XCTAssertEqual(fitted.map { $0.x }.max(),1)
        XCTAssertEqual(fitted.map { $0.x }.min(),-1)
        XCTAssertEqual(WallBoundary.triangles(fitted).count,6)
        XCTAssertFalse(WallBoundary.touchesCeiling(outline,edges:[]))
        let distant = [WallEdge(normal:.init(0,-1),offset:5,ceiling:true)]
        XCTAssertFalse(WallBoundary.touchesCeiling(WallBoundary.fitted(outline,edges:distant),edges:distant))
    }
    func testWallTriangulationPreservesConcaveOutlineAndBothWindings() {
        let polygon: [SIMD2<Float>] = [.init(0,0),.init(3,0),.init(3,1),.init(1,1),.init(1,3),.init(0,3)]
        for points in [polygon,Array(polygon.reversed())] {
            let indices = WallBoundary.triangles(points)
            XCTAssertEqual(indices.count,12)
            var area: Float = 0
            for i in stride(from:0,to:indices.count,by:3) {
                let a = points[Int(indices[i])], b = points[Int(indices[i+1])], c = points[Int(indices[i+2])]
                area += abs(WallBoundary.cross(b-a,c-a))/2
            }
            XCTAssertEqual(area,5,accuracy:0.0001)
        }
        XCTAssertTrue(WallBoundary.triangles([.init(0,0),.init(1,1),.init(0,1),.init(1,0)]).isEmpty)
        let clipped = WallBoundary.fitted(polygon,edges:[WallEdge(normal:.init(-1,0),offset:2,ceiling:false)])
        XCTAssertTrue(clipped.allSatisfy { $0.x <= 2.001 })
    }
    func testWallVoiceRoutesColorsWithoutConfusingRoomControls() {
        for input in ["Jarvis, deixa essa parede branca", "pode mudar a cor dessa parede para branco?", "troca a parede cinza para branca"] {
            XCTAssertEqual(WallARCommand.parse(input,inStudio:false),.finish(.white),input)
        }
        XCTAssertEqual(WallARCommand.parse("agora azul",inStudio:true),.finish(.blue))
        XCTAssertEqual(WallARCommand.parse("coloca textura de madeira",inStudio:true),.finish(.wood))
        XCTAssertEqual(WallARCommand.parse("aplique cimento nessa parede",inStudio:false),.finish(.concrete))
        XCTAssertEqual(WallARCommand.parse("Oi Jarvis abre o modo AR",inStudio:false),.open)
        XCTAssertEqual(WallARCommand.parse("essa parede",inStudio:true),.select)
        XCTAssertEqual(WallARCommand.parse("desfaz",inStudio:true),.undo)
        XCTAssertEqual(WallARCommand.parse("fecha o modo AR",inStudio:true),.close)
        for input in ["não pinte essa parede branca","ele disse pinta a parede branca","liga a luz branca","muda a luz da parede para azul","pinta metade da parede de azul","coloca imagem na parede branca","se pintar a parede branca"] {
            XCTAssertNil(WallARCommand.parse(input,inStudio:true),input)
        }
        XCTAssertNil(WallARCommand.parse("agora azul",inStudio:false))
        XCTAssertNil(WallARCommand.parse("desfaz",inStudio:false))
    }

    func testWallTrackingHidesUntilStableAndResetsOnInterruption() {
        var gate = WallTrackingGate()
        XCTAssertFalse(gate.update(normal:false,at:0))
        XCTAssertFalse(gate.update(normal:true,at:1))
        XCTAssertFalse(gate.update(normal:true,at:1.5))
        XCTAssertTrue(gate.update(normal:true,at:1.7))
        XCTAssertFalse(gate.update(normal:false,at:2))
        XCTAssertFalse(gate.update(normal:true,at:2.1))
        XCTAssertFalse(gate.update(normal:true,at:2.5))
        XCTAssertTrue(gate.update(normal:true,at:2.8))
        XCTAssertFalse(gate.update(normal:true,at:.nan))
    }

    @MainActor func testWallPBRResourcesAndRender() throws {
        for kind in ["wood","concrete","plaster"] {
            for channel in ["Color","NormalGL","Roughness"] {
                let path = try XCTUnwrap(Bundle.main.path(forResource:"AR_\(kind)_\(channel)",ofType:"jpg"))
                let image = try XCTUnwrap(UIImage(contentsOfFile:path)?.cgImage)
                XCTAssertEqual(image.width,2048); XCTAssertEqual(image.height,2048)
            }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable; physical AR still requires device verification") }
        let scene = SCNScene()
        scene.background.contents = UIColor(white:0.08,alpha:1)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0,0,5)
        camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 2
        scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni
        light.light?.intensity = 1100; light.position = SCNVector3(-2,3,4); scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)
        for (i, finish) in [WallFinish.white,.wood,.concrete].enumerated() {
            let geometry = SCNPlane(width:1.4,height:2.8)
            let material = WallMaterials.make(finish)
            XCTAssertEqual(material.lightingModel,.physicallyBased)
            XCTAssertNotNil(material.normal.contents)
            XCTAssertEqual(material.diffuse.mipFilter,.linear)
            geometry.materials = [material]
            let node = SCNNode(geometry:geometry); node.position.x = Float(i-1)*1.6
            scene.rootNode.addChildNode(node)
        }
        let renderer = SCNRenderer(device:device,options:nil); renderer.scene = scene; renderer.pointOfView = camera
        let image = renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
        let attachment = XCTAttachment(image:image); attachment.name = "Wall-AR-PBR-2K-preview"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(image.cgImage)
    }
    func testConversationalAliasesRespectNegationAndDeviceScope() {
        for text in ["Ah, liga o flash", "Jarvis, acende a lanterna", "Ei Jarvis, pode acender o flash pra mim?", "deixa o flash ligado", "por favor, ligue a luz do celular", "quero que você acenda minha lanterna", "então, Jarvis, liga o flash de novo"] {
            XCTAssertEqual(PhoneIntentPhrases.torch(text), .torchOn, text)
        }
        for text in ["apaga o flash", "deixa a lanterna apagada", "ah, apaga a luz do celular", "pode desligar minha lanterna por favor"] {
            XCTAssertEqual(PhoneIntentPhrases.torch(text), .torchOff, text)
        }
        for text in ["não liga o flash", "não apague a lanterna", "ele disse liga o flash", "acenda a luz do quarto", "liga o flash e a cafeteira", "quero que você não ligue a lanterna"] {
            XCTAssertNil(PhoneIntentPhrases.torch(text), text)
        }
        XCTAssertEqual(PhoneSystemVoice.action("Ah, pode ligar o Wi-Fi do meu celular?"), .wifiOn)
    }
    func testJarvisAudioCacheExpiresBoundsMemoryAndRejectsIncompletePCM() {
        var cache = JarvisReplyCache(); let t = Date()
        let audio = Data(repeating: 1, count: 4)
        cache.insert(audio, for: "ok", now: t)
        XCTAssertEqual(cache.audio(for: "ok", now: t.addingTimeInterval(1)), audio)
        XCTAssertNil(cache.audio(for: "outro", now: t))
        XCTAssertNil(cache.audio(for: "ok", now: t.addingTimeInterval(301)))
        cache.insert(Data([1]), for: "incompleto", now: t)
        XCTAssertNil(cache.audio(for: "incompleto", now: t))
        for i in 0..<5 { cache.insert(Data(repeating: 1, count: JarvisReplyCache.maxEntryBytes), for: "\(i)", now: t.addingTimeInterval(Double(i))) }
        XCTAssertNil(cache.audio(for: "0", now: t.addingTimeInterval(5)))
        XCTAssertNotNil(cache.audio(for: "4", now: t.addingTimeInterval(5)))
    }
    func testQuickRepliesUseOriginalJarvisVoiceAndValidPCM() throws {
        let file = try XCTUnwrap(Bundle.main.url(forResource: "JarvisQuickReplies", withExtension: "json"))
        let bank = try JSONDecoder().decode(JarvisQuickReplyBank.self, from: Data(contentsOf: file))
        XCTAssertEqual(bank.voice, "a5b93aeddcc948c19ea04f0afe9d178c")
        XCTAssertEqual(bank.sampleRate, 24000)
        XCTAssertNotNil(bank.replies["Comando encaminhado."])
        for (_, encoded) in bank.replies {
            let pcm = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertGreaterThan(pcm.count, 4800)
            XCTAssertTrue(pcm.count.isMultiple(of: 2))
            XCTAssertTrue(pcm.contains { $0 != 0 })
        }
    }
    func testEndpointAllowsBriefPausesAndWaitsForOngoingSpeech() {
        XCTAssertGreaterThan(WakeConversationWindow.endpointDelay(at: 10.66, partial: 10, voice: 9.8), 0.2)
        XCTAssertEqual(WakeConversationWindow.endpointDelay(at: 10.91, partial: 10, voice: 9.8), 0)
        XCTAssertGreaterThan(WakeConversationWindow.endpointDelay(at: 10.66, partial: 10, voice: 10.6), 0.4)
        XCTAssertEqual(WakeConversationWindow.endpointDelay(at: 14, partial: 10, voice: 14), 0)
    }

    func testLocalAutomationCommandsAreExactAndDoNotExecuteNegations() {
        XCTAssertEqual(PhoneSystemVoice.action("Oi Jarvis, pagar"), .wallet)
        XCTAssertEqual(PhoneSystemVoice.action("Jarvis, ligue o Wi-Fi"), .wifiOn)
        XCTAssertEqual(PhoneSystemVoice.action("desligue os dados móveis"), .cellularOff)
        XCTAssertEqual(PhoneSystemVoice.action("libere a rotação"), .rotationUnlock)
        XCTAssertEqual(PhoneSystemVoice.action("teste o atalho"), .shortcutCheck)
        for s in ["não ligue o wifi", "pagar mil reais", "explique como ligar o bluetooth", "ligue o wifi e desligue os dados", "pagar para Ana"] {
            XCTAssertNil(PhoneSystemVoice.action(s), s)
        }
    }
    func testShortcutReceiptRejectsReplayExpiredWrongVersionAndDuplicateFields() throws {
        let now = Date()
        let good = try XCTUnwrap(URL(string: "jarvisiphone://shortcut-receipt?token=test&result=JARVIS_SISTEMA_14"))
        XCTAssertTrue(PhoneShortcutReceipt.accepts(good, token: "test", expires: now.addingTimeInterval(10), now: now))
        XCTAssertFalse(PhoneShortcutReceipt.accepts(good, token: "different", expires: now.addingTimeInterval(10), now: now))
        XCTAssertFalse(PhoneShortcutReceipt.accepts(good, token: "test", expires: now, now: now))
        for suffix in ["&token=test", "&result=JARVIS_SISTEMA_14", "#fragment"] {
            XCTAssertFalse(PhoneShortcutReceipt.accepts(URL(string:good.absoluteString + suffix)!, token:"test", expires:now.addingTimeInterval(10), now:now))
        }
        let probe = URLComponents(url: PhoneShortcutReceipt.probeURL(token: "x&y"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(probe.queryItems?.first { $0.name == "text" }?.value, "verificar_atalho")
        let callback = URLComponents(string: probe.queryItems!.first { $0.name == "x-success" }!.value!)!
        XCTAssertEqual(callback.queryItems?.first?.value, "x&y")
    }
    @MainActor func testLockedSystemActionsDoNotAttemptToOpenAnotherApp() async {
        for phrase in ["Jarvis pagar", "ligue o bluetooth", "desligue os dados móveis"] {
            let reply = await PhoneLocalKit.resolve(phrase, readOnly: true)
            XCTAssertEqual(reply, "Desbloqueie e abra o Jarvis para encaminhar esta ação ao Atalhos.")
        }
    }

    @MainActor func testPhoneContextCommands() {
        XCTAssertEqual(HandsetContext.parse("Oi, Jarvis, quantos passos hj?"), .steps)
        XCTAssertEqual(HandsetContext.parse("qual foi a última notificação?"), .notification)
        XCTAssertEqual(HandsetContext.parse("ligue pra Ana"), .call("Ana"))
        XCTAssertEqual(HandsetContext.parse("mande um SMS para Ana dizendo Olá!"), .sms("Ana", "Olá!"))
        XCTAssertNil(HandsetContext.parse("ligue para Ana no WhatsApp"))
        XCTAssertEqual(PhoneLocalKit.torchAction("Ei Jarvis, liga a lanterna de novo"), .torchOn)
    }
    @MainActor func testRelativeBrightnessWhenLocked() async {
        let result = await PhoneLocalKit.resolve("diminui o brilho", readOnly: true)
        XCTAssertEqual(result, "Abra o Jarvis no iPhone desbloqueado para executar essa ação.")
    }
    @MainActor func testVoiceVisionModes() {
        XCTAssertEqual(RemoteAssistant.visionCommand("Jarvis, o que estou vendo?"), .once)
        XCTAssertEqual(RemoteAssistant.visionCommand("visão ao vivo"), .start)
        XCTAssertEqual(RemoteAssistant.visionCommand("parar visão"), .stop)
        XCTAssertNil(RemoteAssistant.visionCommand("não abra a câmera"))
    }
    @MainActor func testBrightnessPhrasesResolveOnPhone() async {
        for phrase in ["Jarvis, ajusta o brilho pra 40 %", "Coloca o brilho em quarenta por cento"] {
            let reply = await PhoneLocalKit.resolve(phrase, readOnly: true)
            XCTAssertEqual(reply, "Abra o Jarvis no iPhone desbloqueado para executar essa ação.", phrase)
        }
    }
    @MainActor func testSpotifyPersistsOnlyAcknowledgedDevice() {
        let defaults = UserDefaults.standard
        let keys = ["jarvis.spotify.phone","jarvis.spotify.name"]
        let original = keys.map { defaults.string(forKey:$0) }
        defer { for (key, old) in zip(keys, original) { defaults.set(old, forKey:key) } }
        let phone = RemoteAssistant()
        phone.acceptSpotifyStatus(["state":"bound","confirmed":true,"deviceId":"test-confirmed","deviceName":"iPhone de teste"])
        phone.acceptSpotifyStatus(["state":"choose","phones":[["id":"test-other","name":"Telefone","active":true]]])
        phone.selectSpotifyPhone("test-other") // No bridge acknowledgement.
        phone.acceptSpotifyStatus(["state":"bound","confirmed":false,"deviceId":"test-other","deviceName":"Outro"])
        XCTAssertEqual(phone.spotifyID, "test-confirmed")
        XCTAssertEqual(phone.spotifyPhones.first?["id"], "test-other")
        XCTAssertEqual(RemoteAssistant().spotifyName, "iPhone de teste")
        XCTAssertTrue(RemoteAssistant.isSpotifyBindingCommand("Oi Jarvis, vincula o Spotify neste iPhone!"))
        XCTAssertFalse(RemoteAssistant.isSpotifyBindingCommand("Toque rock no Spotify"))
    }
    @MainActor func testMuteEndsCurrentTurnAndIgnoresSpeechUntilFreshWake() async {
        let phone = RemoteAssistant()
        phone.heardCall()
        await phone.say("Oi Jarvis")
        XCTAssertEqual(phone.lines.last?.text, PhoneLocalKit.greeting)
        let count = phone.lines.count
        await phone.say("Jarvis, muta")
        XCTAssertFalse(phone.isSpeaking)
        XCTAssertFalse(phone.followUp)
        XCTAssertFalse(phone.showingFace)
        await phone.say("Oi")
        XCTAssertEqual(phone.lines.count, count)
        phone.heardCall()
        await phone.say("Oi Jarvis")
        XCTAssertEqual(phone.lines.count, count + 2)
        XCTAssertEqual(phone.lines.last?.text, PhoneLocalKit.greeting)
        await phone.say("Jarvis, muta")
    }
    func testHarpPinchPullReleaseOnceAndCancelLostHand() {
        var board=AirStringBoard(); board.preset()
        let p=CGPoint(x:0.16,y:0.5)
        XCTAssertTrue(board.consume(point:p,pinchRatio:0.8,time:1).isEmpty)
        XCTAssertTrue(board.consume(point:p,pinchRatio:0.1,time:1.05).isEmpty)
        XCTAssertTrue(board.consume(point:p,pinchRatio:0.1,time:1.15).isEmpty)
        XCTAssertNotNil(board.held)
        XCTAssertTrue(board.consume(point:CGPoint(x:0.28,y:0.5),pinchRatio:0.1,time:1.20).isEmpty)
        XCTAssertGreaterThan(board.offset(index:0,position:0.5,time:1.20).x,0.02)
        XCTAssertTrue(board.consume(point:CGPoint(x:0.28,y:0.5),pinchRatio:0.8,time:1.25).isEmpty)
        let notes=board.consume(point:CGPoint(x:0.28,y:0.5),pinchRatio:0.8,time:1.34)
        XCTAssertEqual(notes.map(\.note),[60]);XCTAssertGreaterThan(notes[0].velocity,70)
        XCTAssertTrue(board.consume(point:CGPoint(x:0.28,y:0.5),pinchRatio:0.8,time:1.38).isEmpty)
        board.beginPull(p);board.dragPull(CGPoint(x:0.30,y:0.5));board.resetGesture()
        XCTAssertTrue(board.endPull(time:2).isEmpty)
        _ = board.consume(point:p,pinchRatio:0.8,time:2)
        board.beginPull(p)
        XCTAssertTrue(board.consume(point:p,pinchRatio:0.8,time:5).isEmpty)
        XCTAssertNil(board.held)
    }
    func testHarpCreationBoundsCrossingsAndFiniteIdleAnimation() {
        var board=AirStringBoard();board.preset()
        XCTAssertEqual(board.strings.count,8)
        XCTAssertEqual(board.strings.map(\.note),[60,62,64,65,67,69,71,72])
        for i in board.strings.indices {
            XCTAssertEqual(board.offset(index:i,position:0.5,time:10),.zero)
        }
        board.beginPull(CGPoint(x:0.16,y:0.5));board.dragPull(CGPoint(x:0.26,y:0.5));_ = board.endPull(time:10)
        XCTAssertEqual(board.offset(index:0,position:0,time:10.1),.zero)
        XCTAssertEqual(board.offset(index:0,position:0.5,time:10.1,reducedMotion:true),.zero)
        XCTAssertTrue(board.offset(index:0,position:0.5,time:10.1).x.isFinite)
        XCTAssertFalse(board.add(from:CGPoint(x:Double.nan,y:0),to:.zero))
        XCTAssertFalse(board.add(from:.zero,to:CGPoint(x:0.01,y:0.01)))
        board.mode = .create
        for (t,p,r) in [(1.0,CGPoint(x:0.1,y:0.2),0.8),(1.05,CGPoint(x:0.1,y:0.2),0.1),(1.15,CGPoint(x:0.1,y:0.2),0.1),(1.2,CGPoint(x:0.3,y:0.2),0.1),(1.25,CGPoint(x:0.5,y:0.2),0.8),(1.34,CGPoint(x:0.5,y:0.2),0.8)] {
            XCTAssertTrue(board.consume(point:p,pinchRatio:r,time:t).isEmpty)
        }
        XCTAssertEqual(board.strings.count,9)
        XCTAssertNil(AirStringBoard.crossing(CGPoint(x:0.5,y:0.5),CGPoint(x:0.6,y:0.5),CGPoint(x:0.5,y:0.1),CGPoint(x:0.5,y:0.9)))
    }
    @MainActor func testHarpAndTranslationVoiceEntryPoints() {
        for text in ["Jarvis, abre a harpa", "modo harpa", "quero tocar harpa", "abre as cordas no ar", "abre os instrumentos"] {
            XCTAssertEqual(PhoneLocalKit.studio(for:text),"music",text)
        }
        XCTAssertEqual(PhoneLocalKit.studio(for:"traduz o que estou vendo"),"translate")
        XCTAssertEqual(PhoneLocalKit.studio(for:"abre o tradutor"),"translate")
        XCTAssertEqual(PhoneLocalKit.studio(for:"abre o modo libras"),"libras")
        XCTAssertNil(PhoneLocalKit.studio(for:"não abre a harpa"))
        XCTAssertNil(PhoneLocalKit.studio(for:"toca harpa no spotify"))
        XCTAssertEqual(StudioInstrument.harp.program,46)
        XCTAssertEqual(StudioInstrument.electricGuitar.program,27)
        XCTAssertEqual(PhoneLocalKit.studio(for:"abre a guitarra"),"music")
        XCTAssertEqual(PhoneLocalKit.instrument(for:"abre a guitarra"),.electricGuitar)
        XCTAssertEqual(PhoneLocalKit.instrument(for:"abre o violão"),.guitar)
        var board=AirStringBoard();board.preset(guitar:true)
        XCTAssertEqual(board.strings.map(\.note),[40,45,50,55,59,64])
    }
    @MainActor func testCameraOCRRecognizesPrintedTextAndHarpRenders() async throws {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:800,height:240),format:format).image { ctx in
            UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:800,height:240))
            ("HELLO WORLD" as NSString).draw(at:CGPoint(x:50,y:70),withAttributes:[.font:UIFont.systemFont(ofSize:72),.foregroundColor:UIColor.black])
        }
        let rows=try CameraTextReader.read(XCTUnwrap(image.cgImage))
        XCTAssertTrue(rows.contains { $0.text.uppercased().contains("HELLO WORLD") })
        let view=UIHostingController(rootView:AirStrings())
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous=scene.windows.first(where: \.isKeyWindow)
        let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:428,height:850)
        window.rootViewController=view;window.makeKeyAndVisible()
        defer { window.isHidden=true;previous?.makeKeyAndVisible() }
        view.view.frame=window.bounds;view.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(300))
        let screenshot=UIGraphicsImageRenderer(size:view.view.bounds.size).image { _ in view.view.drawHierarchy(in:view.view.bounds,afterScreenUpdates:true) }
        let pixels=try XCTUnwrap(screenshot.cgImage?.dataProvider?.data)
        let data=Data(bytes:CFDataGetBytePtr(pixels)!,count:CFDataGetLength(pixels))
        XCTAssertGreaterThan(Set(data).count,20,"The screenshot must contain rendered controls and colored strings")
        let attachment=XCTAttachment(image:screenshot);attachment.name="Harpa-no-ar-rev16";attachment.lifetime = .keepAlways;add(attachment)
    }

    func testBundledInstrumentsRenderAudibleSamples() throws {
        let bank = try XCTUnwrap(Bundle.main.url(forResource: "JarvisInstruments", withExtension: "sf2"))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        var checks = StudioInstrument.allCases.map { (instrument: $0, note: UInt8($0 == .drums ? 38 : 60), velocity: UInt8(100)) }
        for note: UInt8 in [36, 60, 84] {
            for velocity: UInt8 in [65, 96, 110] {
                checks.append((.flute, note, velocity))
            }
        }
        for (instrument, note, velocity) in checks {
            let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            try sampler.loadSoundBankInstrument(at: bank, program: instrument.program,
                                                bankMSB: instrument == .drums ? 0x78 : 0x79, bankLSB: 0)
            try engine.start()
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            sampler.startNote(note, withVelocity: velocity, onChannel: 0)
            var peak: Float = 0
            for _ in 0..<20 {
                if try engine.renderOffline(1024, to: buffer) == .success, let samples = buffer.floatChannelData {
                    for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][index])) }
                }
            }
            engine.stop()
            XCTAssertGreaterThan(peak, 0.0001, "\(instrument.rawValue), MIDI \(note), velocidade \(velocity)")
        }
    }
    @MainActor func testConversationRoutesTorchToPhoneButNotBedroomLight() {
        for s in ["Oi Jarvis, você pode acender a lanterna do meu celular?", "Liga o flash pra mim", "Acende minha lanterna"] {
            XCTAssertEqual(PhoneLocalKit.torchAction(s), .torchOn, s)
        }
        XCTAssertEqual(PhoneLocalKit.torchAction("Pode desligar a lanterna agora?"), .torchOff)
        for s in ["acenda a luz do quarto","não ligue a lanterna","ligue a lanterna e a cafeteira"] { XCTAssertNil(PhoneLocalKit.torchAction(s),s) }
    }
    func testNotificationQueueIsLiteralFreshAndOrdered() {
        var q = VoiceInbox(); let t=Date()
        XCTAssertTrue(q.insert("  Oi   Ana  ",now:t))
        XCTAssertFalse(q.insert("Oi Ana",now:t))
        XCTAssertFalse(q.insert("JARVIS_COMANDO",now:t))
        XCTAssertTrue(q.insert("ligue a luz",now:t))
        XCTAssertEqual(q.next(now:t), "Oi Ana")
        XCTAssertEqual(q.next(now:t), "ligue a luz")
        XCTAssertTrue(q.insert("antiga",now:t))
        XCTAssertNil(q.next(now:t.addingTimeInterval(91)))
    }
    @MainActor
    func testUnpairedPhoneCanAnswerTimeOffline() async {
        let assistant = RemoteAssistant()
        assistant.paired = false
        assistant.ready = false
        await assistant.say("Que horas são?")
        XCTAssertEqual(assistant.lines.first?.text, "Que horas são?")
        XCTAssertEqual(assistant.lines.last?.user, false)
        XCTAssertTrue(assistant.lines.last?.text.hasPrefix("Agora são ") == true)
        XCTAssertFalse(assistant.busy)
    }

    @MainActor
    func testLocalTimeDoesNotConsumeCalendarRequest() async {
        let result = await PhoneLocalKit.resolve("Que horas são as reuniões da minha agenda?")
        XCTAssertNil(result)
    }

    func testAlmanacUnderstandsWeatherWithoutTakingAgendaOrTimers() {
        XCTAssertEqual(PhoneAlmanac.request("vai chover amanha em recife"), .weather(.tomorrow, "recife"))
        XCTAssertEqual(PhoneAlmanac.request("previsao do tempo em recife para amanha"), .weather(.tomorrow, "recife"))
        XCTAssertEqual(PhoneAlmanac.request("qual a previsao do tempo para a semana"), .weather(.week, nil))
        XCTAssertEqual(PhoneAlmanac.request("como ta o tempo aqui"), .weather(.now, nil))
        XCTAssertEqual(PhoneAlmanac.request("qual a data de hoje"), .date(0))
        XCTAssertNil(PhoneAlmanac.request("que horas sao as reunioes da minha agenda"))
        XCTAssertNil(PhoneAlmanac.request("qual o tempo de viagem em curitiba"))
        XCTAssertNil(PhoneAlmanac.request("qual a temperatura do meu iphone"))
        XCTAssertNil(PhoneAlmanac.request("coloque musica para chover"))
    }

    func testPhoneCalendarUsesDeviceZoneAcrossMidnight() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T01:05:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        XCTAssertEqual(PhoneAlmanac.calendarReply(.time, date: instant, zone: zone), "Agora são 22:05.")
        XCTAssertEqual(PhoneAlmanac.calendarReply(.weekday(1), date: instant, zone: zone), "Amanhã é sexta-feira.")
        XCTAssertEqual(PhoneAlmanac.calendarReply(.date(0), date: instant, zone: zone), "Hoje é quinta-feira, 1 de janeiro de 2026.")
    }

    @MainActor func testAlmanacDashboardButtonsUseTheLocalRoutes() async {
        let reply = await PhoneLocalKit.resolve("Qual a data e a hora de hoje?")
        XCTAssertNotNil(reply?.range(of: #"Hoje é .+ [0-9]{4}, [0-9]{2}:[0-9]{2}\."#, options: .regularExpression))
        XCTAssertEqual(PhoneAlmanac.request("como esta o tempo hoje"), .weather(.today, nil))
    }

    func testWeatherSelectsTomorrowByLocalDayAndDoesNotInventMissingData() throws {
        let fixture = #"{"current":{"temperature_2m":19.7,"weather_code":2},"daily":{"time":["2026-01-01","2026-01-02"],"weather_code":[0,61],"temperature_2m_min":[18,17],"temperature_2m_max":[30,25],"precipitation_probability_max":[0,80]}}"#
        let forecast = try JSONDecoder().decode(PhoneAlmanac.Forecast.self, from: Data(fixture.utf8))
        XCTAssertTrue(PhoneAlmanac.forecastReply(forecast, period: .now, place: "Em Recife").contains("20 °C"))
        let nextDay = PhoneAlmanac.forecastReply(forecast, period: .tomorrow, place: "Em Recife")
        XCTAssertTrue(nextDay.contains("17 e máxima de 25"))
        XCTAssertTrue(nextDay.contains("80%"))
        XCTAssertTrue(PhoneAlmanac.forecastReply(forecast, period: .afterTomorrow, place: "Em Recife").contains("indisponível"))
    }

    func testAllNineteenActionsHaveUniqueIDs() {
        XCTAssertEqual(PhoneAction.allCases.count, 30)
        XCTAssertEqual(Set(PhoneAction.allCases.map(\.rawValue)).count, 30)
    }

    func testDeepLinkRoutesKnownAction() throws {
        let command = try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=lanterna_ligar")!)
        XCTAssertEqual(command.action, .torchOn)
        XCTAssertNil(command.percentage)
    }

    func testBrightnessAcceptsZeroAndOneHundred() throws {
        for value in [0.0, 100.0] {
            XCTAssertEqual(try PhoneCommand(action: .brightness, percentage: value).percentage, value)
        }
    }

    func testPercentageRejectsInvalidAndNonFiniteValues() {
        for value in [-1.0, 100.1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try PhoneCommand(action: .volume, percentage: value))
        }
    }

    func testPercentageOnlyAppliesToSupportedActions() {
        XCTAssertThrowsError(try PhoneCommand(action: .torchOn, percentage: 50))
    }

    func testDeepLinkRejectsUnknownAction() {
        XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=enviar_mensagem")!))
    }

    func testDeepLinkRejectsOtherHostsAndSchemes() {
        for raw in ["https://command?action=volume", "jarvisiphone://other?action=volume", "jarvisiphone://command/other?action=volume"] {
            XCTAssertThrowsError(try PhoneCommand.decode(URL(string: raw)!))
        }
    }

    func testDeepLinkRejectsDuplicateOrUnknownParameters() {
        for query in ["action=volume&action=brilho", "action=volume&value=20&value=30", "action=volume&token=x"] {
            XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?\(query)")!))
        }
    }

    func testDeepLinkRejectsBadNumber() {
        XCTAssertThrowsError(try PhoneCommand.decode(URL(string: "jarvisiphone://command?action=brilho&value=abc")!))
    }

    func testShortcutURLContainsOnlyExpectedPayload() throws {
        let command = try PhoneCommand(action: .volume, percentage: 50)
        let parts = try XCTUnwrap(URLComponents(url: command.systemShortcutURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "shortcuts")
        XCTAssertEqual(parts.host, "run-shortcut")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "name" })?.value, "JARVIS Sistema")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "text" })?.value, "volume|50.0")
    }

    func testShortcutURLWithoutPercentageDoesNotCrash() throws {
        let command = try PhoneCommand(action: .meeting)
        let parts = try XCTUnwrap(URLComponents(url: command.systemShortcutURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "text" })?.value, "reuniao")
    }

    func testAppIntentsExposeSameActionSet() {
        XCTAssertEqual(Set(PhoneActionParameter.allCases.map(\.rawValue)), Set(PhoneAction.allCases.map(\.rawValue)))
    }
}

func roomFixture(detail:Bool=true)->RoomForestRegistration.Capture {
    let walls:[RoomForestRegistration.Wall]=[
        .init(center:SIMD3(0,1,1.5),normal:SIMD3(1,0,0),low:-3,high:0,bottom:0,top:2.5),
        .init(center:SIMD3(4,1,1.5),normal:SIMD3(1,0,0),low:-3,high:0,bottom:0,top:2.5),
        .init(center:SIMD3(2,1,0),normal:SIMD3(0,0,1),low:0,high:4,bottom:0,top:2.5),
        .init(center:SIMD3(2,1,3),normal:SIMD3(0,0,1),low:0,high:4,bottom:0,top:2.5)]
    var points:[RoomForestRegistration.Point]=[]
    for i in 0...12 { for j in 0...12 {
        let x=Float(i)/3,z=Float(i)/4,y=Float(j)*2.5/12
        points += [.init(p:SIMD3(0,y,z),n:SIMD3(1,0,0),kind:1),.init(p:SIMD3(4,y,z),n:SIMD3(1,0,0),kind:1),.init(p:SIMD3(x,y,0),n:SIMD3(0,0,1),kind:1),.init(p:SIMD3(x,y,3),n:SIMD3(0,0,1),kind:1)]
        if detail {
            points.append(.init(p:SIMD3(0.45+Float(i)*0.06,0.65,0.65+Float(j)*0.05),n:SIMD3(0,1,0),kind:0))
            points.append(.init(p:SIMD3(0.45+Float(i)*0.06,Float(j)*0.05,0.65),n:SIMD3(0,0,1),kind:0))
            points.append(.init(p:SIMD3(0.45,Float(j)*0.05,0.65+Float(i)*0.05),n:SIMD3(1,0,0),kind:0))
        }
    }}
    return .init(floor:0,walls:walls,points:points)
}
