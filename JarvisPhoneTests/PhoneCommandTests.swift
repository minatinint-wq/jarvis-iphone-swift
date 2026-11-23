import XCTest
import SwiftUI
import AVFoundation
import SceneKit
import Metal
import ARKit
@testable import JarvisPhone

final class PhoneCommandTests: XCTestCase {
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
    func testSpatialGestureRequiresDeliberatePressAndReleaseAndCancelsOcclusion() {
        var gate=SpatialGesture();let p=CGPoint(x:100,y:100)
        func input(_ ratio:Double,_ time:Double,_ point:CGPoint?=CGPoint(x:100,y:100))->[SpatialGesture.Event] { gate.update(point:point,ratio:ratio,target:"play",push:nil,time:time) }
        XCTAssertTrue(input(0.1,1).isEmpty) // appearing already pinched cannot click
        _=input(1,1.1);_=input(1,1.2);_=input(0.1,1.3)
        XCTAssertEqual(input(0.1,1.4),[.press("play")])
        _=input(1,1.5);XCTAssertEqual(input(1,1.6),[.release("play",true)])
        for i in 0..<10 { XCTAssertTrue(input(1,1.7+Double(i)*0.07).isEmpty) }
        _=input(0.1,2.4);_=input(0.1,2.5)
        XCTAssertEqual(input(0.1,2.6,nil),[.cancel])
        XCTAssertTrue(input(1,2.7,p).isEmpty)
    }
    func testSpatialGestureHoldDragsWithoutClickAndPokeNeedsRetraction() {
        var gate=SpatialGesture();let p=CGPoint(x:100,y:100)
        func input(_ r:Double,_ t:Double,_ push:Double?=nil)->[SpatialGesture.Event] { gate.update(point:p,ratio:r,target:"card",push:push,time:t) }
        _=input(1,1);_=input(1,1.1);_=input(0.1,1.2);_=input(0.1,1.3)
        _=input(0.1,1.4);_=input(0.1,1.5);_=input(0.1,1.6)
        XCTAssertEqual(input(0.1,1.75),[.drag("card")])
        _=input(1,1.8);XCTAssertEqual(input(1,1.9),[.release("card",false)])
        gate.reset();_=input(1,3,0);_=input(1,3.1,0);_=input(1,3.2,0)
        XCTAssertEqual(input(1,3.3,0.04),[.poke("card")])
        for i in 1...30 { XCTAssertTrue(input(1,3.3+Double(i)*0.1,0.05).isEmpty) }
    }
    @MainActor func testSpatialDashboardRendersRealModuleCards() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let view=ARSCNView(frame:.zero);view.scene=SCNScene();view.scene.background.contents=UIColor(white:0.07,alpha:1)
        let panel=SpatialPanel(view:view)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=0.48
        camera.camera?.zNear=0.01;camera.camera?.zFar=10
        camera.position=SCNVector3(0,0,1);view.scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=view.scene;renderer.pointOfView=camera
        for module in [SpatialModule.dashboard,.home,.phone] {
            panel.preview(module)
            let screenshot=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:900),antialiasingMode:.multisampling4X)
            let attachment=XCTAttachment(image:screenshot);attachment.name="Spatial-panel-\(module.rawValue)";attachment.lifetime = .keepAlways;add(attachment)
            XCTAssertNotNil(screenshot.cgImage)
            let cg=try XCTUnwrap(screenshot.cgImage)
            var pixels=[UInt8](repeating:0,count:64*64*4)
            let context=try XCTUnwrap(CGContext(data:&pixels,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in:CGRect(x:0,y:0,width:64,height:64))
            XCTAssertGreaterThan(stride(from:0,to:pixels.count,by:4).filter { max(pixels[$0],pixels[$0+1],pixels[$0+2])>100 }.count,30,"Panel must contain visible controls, not a blank snapshot")
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
    func testFasterEndpointStillWaitsForOngoingSpeech() {
        XCTAssertEqual(WakeConversationWindow.endpointDelay(at: 10.66, partial: 10, voice: 9.8), 0)
        XCTAssertGreaterThan(WakeConversationWindow.endpointDelay(at: 10.66, partial: 10, voice: 10.6), 0.4)
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
