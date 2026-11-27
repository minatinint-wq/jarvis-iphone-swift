import SwiftUI

@MainActor struct ImageRequestButton: View {
    @ObservedObject var model: RemoteAssistant
    @State private var editing = false
    @State private var prompt = ""
    var body: some View {
        Button {
            editing = true
        } label: {
            Label("Gerar imagem", systemImage: "photo.badge.plus")
                .frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.bordered).tint(.cyan)
        .alert("Gerar imagem", isPresented: $editing) {
            if model.ready {
                TextField("Descreva a imagem", text: $prompt)
                Button("Gerar") {
                    let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    prompt = ""
                    Task { await model.say("Gere uma imagem de " + request) }
                }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || model.isSpeaking)
            }
            Button("Fechar", role: .cancel) {}
        } message: {
            if !model.ready { Text("Conecte este iPhone à ponte do Jarvis no PC para gerar imagens.") }
        }
    }
}

@MainActor struct ArtworkOverlay: View {
    @ObservedObject var model: RemoteAssistant
    @State private var enlarged = false
    var body: some View {
        if let image = model.presentedArtwork {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.96).ignoresSafeArea()
                GeometryReader { bounds in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: bounds.size.width * (enlarged ? 2 : 1))
                            .frame(minHeight: bounds.size.height)
                            .accessibilityLabel("Imagem gerada pelo Jarvis")
                            .onTapGesture(count: 2) { enlarged.toggle() }
                    }
                }
                HStack {
                    Button { enlarged.toggle() } label: { Image(systemName: enlarged ? "minus.magnifyingglass" : "plus.magnifyingglass") }
                        .accessibilityLabel(enlarged ? "Reduzir imagem" : "Ampliar imagem")
                    Button { model.presentedArtwork = nil; enlarged = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar imagem")
                }.buttonStyle(.bordered).padding()
            }.foregroundStyle(.white).accessibilityAddTraits(.isModal)
        }
    }
}

@main @MainActor struct JarvisPhoneApp: App {
    init() {
        do { let removed=try SpatialSingleMap.migrate(at:SpatialArchive.file);NSLog("[SpatialMap] single-map policy ready; removed=%d",removed) }
        catch { NSLog("[SpatialMap] map cleanup postponed: %@",error.localizedDescription) }
    }
    @StateObject private var controller=PhoneController.shared
    @StateObject private var remote=RemoteAssistant.shared
    @State private var settingsPresented=false
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AssistantView(model:remote,openSettings:{settingsPresented=true})
            .preferredColorScheme(.dark).tint(.cyan)
            .sheet(isPresented:$settingsPresented) {
                DashboardView(controller:controller)
                    .safeAreaInset(edge:.top) {
                        HStack { Text("Ajustes do Jarvis").font(.headline);Spacer();Button("Fechar") { settingsPresented=false } }.padding()
                    }
            }
            .overlay { ArtworkOverlay(model: remote) }
            .fullScreenCover(isPresented: $remote.showingFace) {
                WakeFace(model:remote).overlay { ArtworkOverlay(model: remote) }
            }
            .onAppear{if scenePhase == .active {remote.foreground(true)}}
            .onOpenURL{url in
                if url.scheme == "jarvisiphone",url.host == "biblioteca" { settingsPresented=false;Task { await remote.openSpatialLibrary(url) } }
                else if url.scheme == "jarvisiphone", url.host == "shortcut-receipt" {_ = controller.acceptShortcutReceipt(url)}
                else if url.scheme == "jarvisiphone", url.host == "automacoes" {settingsPresented=true;controller.sheet = .setup}
                else if url.scheme?.lowercased()=="jarvisiphone",url.host?.lowercased()=="rosto" {settingsPresented=false;remote.showingFace=true}
                else if url.scheme?.lowercased()=="jarvisiphone",url.host?.lowercased()=="conversar" {settingsPresented=false;remote.showingFace=true;remote.activate()}
                else if url.scheme=="jarvisiphone",url.host=="parear" {settingsPresented=false;if !remote.paired {Task{await remote.pair(url.absoluteString)}}}
                else {settingsPresented=true;Task{await controller.handle(url:url)}}
            }
            .onChange(of:scenePhase){_,phase in
                if phase == .active {controller.refreshBattery();remote.foreground(true)}
                else if phase == .background {remote.foreground(false)}
            }
        }
    }
}
