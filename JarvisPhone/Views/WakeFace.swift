import SwiftUI
import SceneKit

final class HelmetRig {
    let scene = SCNScene(), head = SCNNode(), lens = SCNMaterial()
    init() {
        let colors:[UIColor] = [UIColor(red:0.52,green:0.035,blue:0.09,alpha:1),UIColor(red:0.94,green:0.65,blue:0.27,alpha:1),.cyan,UIColor(white:0.10,alpha:1)]
        let mats = colors.enumerated().map { i,color -> SCNMaterial in
            let m = i == 2 ? lens : SCNMaterial()
            m.diffuse.contents = color; m.lightingModel = .physicallyBased
            m.metalness.contents = i < 2 ? 0.69 : 0.1; m.roughness.contents = i < 2 ? 0.30 : 0.42
            return m
        }
        scene.rootNode.addChildNode(head)
        if let url=Bundle.main.url(forResource:"WakeHelmet",withExtension:"mesh"), let b=try? Data(contentsOf:url),
           b.starts(with:Data("XLV1".utf8)), b.count >= 8 {
            var offset = 4
            func read() -> Int { defer { offset += 4 }; return b.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))) } }
            func take(_ n:Int) -> Data { defer { offset += n }; return b.subdata(in:offset..<offset+n) }
            let count=read()
            for _ in 0..<min(count,80) {
                guard offset+12<=b.count else { break }; let material=read(), vertices=read(), faces=read()
                guard mats.indices.contains(material),vertices>0,faces>0,offset+vertices*24+faces*12<=b.count else { break }
                let v=SCNGeometrySource(data:take(vertices*12),semantic:.vertex,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:12)
                let n=SCNGeometrySource(data:take(vertices*12),semantic:.normal,vectorCount:vertices,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:0,dataStride:12)
                let e=SCNGeometryElement(data:take(faces*12),primitiveType:.triangles,primitiveCount:faces,bytesPerIndex:4)
                let g=SCNGeometry(sources:[v,n],elements:[e]);g.materials=[mats[material]];head.addChildNode(SCNNode(geometry:g))
            }
        }
        let cam=SCNNode();cam.camera=SCNCamera();cam.camera?.fieldOfView=34;cam.camera?.zNear=0.05;cam.position=SCNVector3(0,0,4)
        scene.rootNode.addChildNode(cam)
        func light(_ position:SCNVector3,_ color:UIColor,_ power:CGFloat) {
            let node=SCNNode();node.position=position;node.light=SCNLight();node.light?.type = .omni
            node.light?.color=color;node.light?.intensity=power;scene.rootNode.addChildNode(node)
        }
        light(SCNVector3(-3,4,4),UIColor(red:1,green:0.92,blue:0.79,alpha:1),1450)
        light(SCNVector3(3,1.2,2),UIColor(red:0.69,green:0.85,blue:1,alpha:1),870)
        light(SCNVector3(0,2,-3),.white,1500)
        let env=UIGraphicsImageRenderer(size:CGSize(width:256,height:128)).image { ctx in
            UIColor(white:0.33,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:256,height:128))
            UIColor(white:0.9,alpha:1).setFill();ctx.fill(CGRect(x:28,y:21,width:58,height:41));ctx.fill(CGRect(x:162,y:8,width:21,height:67))
        };scene.lightingEnvironment.contents=env;scene.lightingEnvironment.intensity=0.85
    }
}
struct HelmetViewport: UIViewRepresentable {
    var yaw:Double; var pitch:Double; var energy:Double
    func makeCoordinator() -> HelmetRig { HelmetRig() }
    func makeUIView(context:Context) -> SCNView {
        let v=SCNView();v.scene=context.coordinator.scene;v.backgroundColor = .clear
        v.isOpaque=false;v.antialiasingMode = .multisampling2X;v.preferredFramesPerSecond=30;return v
    }
    func updateUIView(_ view:SCNView,context:Context) {
        let r=context.coordinator;r.head.eulerAngles=SCNVector3(Float(pitch),Float(yaw),0)
        r.lens.emission.contents=UIColor(red:0.1+energy*0.48, green:0.64+energy*0.33,blue:1,alpha:1)
        view.setNeedsDisplay()
    }
}

@MainActor struct WakeFace: View {
    @ObservedObject var model:RemoteAssistant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var yaw = -0.18, pitch = 0.0
    @GestureState private var drag:CGSize = .zero
    var body:some View {
        ZStack {
            LinearGradient(colors:[Color(red:0.027,green:0.049,blue:0.078),.black],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
            VStack(spacing:12) {
                HStack {
                    Text("J.A.R.V.I.S.   /   MARK XLV").font(.caption.monospaced().weight(.semibold)).foregroundStyle(.cyan)
                    Spacer()
                    Button { model.showingFace=false } label:{ Image(systemName:"xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.accessibilityLabel("Voltar ao painel")
                }
                Spacer(minLength:0)
                TimelineView(.animation(minimumInterval:1.0/25, paused:reduceMotion || phase != .active)) { moment in
                    let t=moment.date.timeIntervalSinceReferenceDate
                    let level=model.isSpeaking ? model.playbackLevel() : 0
                    ZStack {
                        RadialGradient(colors:[.cyan.opacity(0.11+level*0.09),.clear],center:.center,startRadius:10,endRadius:185)
                        HelmetViewport(yaw:yaw+drag.width*0.009+(reduceMotion ? 0 : sin(t*0.45)*0.048),pitch:pitch+drag.height*0.004+(reduceMotion ? 0 : level*0.035),energy:level)
                    }
                }.aspectRatio(0.95,contentMode:.fit)
                 .gesture(DragGesture().updating($drag){ v,d,_ in d=v.translation }.onEnded { v in yaw += v.translation.width*0.009;pitch=max(-0.55,min(0.55,pitch+v.translation.height*0.004)) })
                 .accessibilityLabel("Máscara tridimensional do Jarvis")
                let status = model.isSpeaking ? "Falando" : model.busy ? "Pensando" : model.recording || model.message == "Ouvindo seu pedido…" ? "Ouvindo" : "Às suas ordens"
                Text(status).font(.title.bold()).foregroundStyle(.white)
                ScrollView { Text(model.lines.last?.text ?? "Diga “Oi, Jarvis” e faça seu pedido.").font(.body).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center) }.frame(maxHeight:105)
                Spacer(minLength:0)
                Button { if model.recording { Task { await model.sendRecording() } } else { model.startListening() } } label:{
                    Label(model.recording ? "Enviar pedido" : "Falar agora",systemImage:model.recording ? "stop.fill" : "mic.fill")
                }.buttonStyle(.borderedProminent).disabled(!model.ready || model.busy).tint(.cyan)
            }.padding(24)
        }.preferredColorScheme(.dark)
    }
}
