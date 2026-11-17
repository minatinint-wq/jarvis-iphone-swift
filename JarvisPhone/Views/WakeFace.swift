import SwiftUI
import UIKit

@MainActor struct WakeFace: View {
    @ObservedObject var model:RemoteAssistant
    var body:some View {
        ZStack {
            LinearGradient(colors:[Color(red:0.027,green:0.049,blue:0.078),.black],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
            VStack(spacing:12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("JARVIS").font(.title2.weight(.bold)).tracking(2)
                        Label(model.ready ? "iPhone conectado" : "Modo local", systemImage: model.ready ? "wave.3.right" : "iphone")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.showingFace=false } label:{ Image(systemName:"xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.accessibilityLabel("Voltar ao painel")
                }
                Spacer(minLength:0)
                HelmetPortrait()
                .frame(maxWidth: .infinity).aspectRatio(0.95, contentMode: .fit)
                .accessibilityLabel("Retrato do Jarvis")
                let status = model.isSpeaking ? "Falando" : model.busy ? "Pensando" : model.followUp || model.message == "Ouvindo seu pedido…" ? "Ouvindo" : "Às suas ordens"
                Text(status).font(.title.bold()).foregroundStyle(.white)
                ScrollView { Text(model.lines.last?.text ?? "Diga “Oi, Jarvis” e faça seu pedido.").font(.body).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center) }.frame(maxHeight:105)
                Spacer(minLength:0)
                ImageRequestButton(model: model)
                HStack {
                    Button { Task { await model.describeView() } } label: { Label("Descrever", systemImage: "camera") }
                        .disabled(!model.cameraAvailable || model.busy)
                    Button { if model.liveVision { model.stopVision() } else { Task { await model.describeView(continuous: true) } } } label: {
                        Label(model.liveVision ? "Parar visão" : "Ao vivo", systemImage: model.liveVision ? "stop.circle" : "eye")
                    }.disabled(!model.cameraAvailable)
                }.buttonStyle(.bordered).tint(.cyan)
                Button { if model.followUp { model.endConversation() } else { model.startListening() } } label:{
                    Label(model.followUp ? "Encerrar conversa" : "Conversar",systemImage:model.followUp ? "stop.fill" : "mic.fill")
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.isSpeaking).tint(.cyan)
            }.padding(24)
        }.preferredColorScheme(.dark)
    }
}

@MainActor struct HelmetPortrait: View {
    private static let portrait: UIImage? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("JarvisWake.appex")),
              let file = bundle.url(forResource: "WakePortrait", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: file.path)
    }()
    var body: some View {
                Group {
                    if let portrait = Self.portrait {
                        Image(uiImage: portrait).resizable().scaledToFit()
                    } else {
                        Image(systemName: "waveform.circle").font(.system(size: 84)).foregroundStyle(.cyan)
                    }
                }
    }
}
