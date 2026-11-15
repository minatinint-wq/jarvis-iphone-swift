import SwiftUI

@main @MainActor struct JarvisPhoneApp: App {
    @StateObject private var controller=PhoneController.shared
    @StateObject private var remote=RemoteAssistant()
    @State private var tab=0
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            TabView(selection:$tab){
                AssistantView(model:remote).tag(0).tabItem{Label("Assistente",systemImage:"waveform.circle")}
                DashboardView(controller:controller).tag(1).tabItem{Label("Meu iPhone",systemImage:"iphone")}
            }.preferredColorScheme(.dark).tint(.cyan)
            .onAppear{if scenePhase == .active {remote.foreground(true)}}
            .onOpenURL{url in
                if url.scheme?.lowercased()=="jarvisiphone",url.host?.lowercased()=="conversar" {tab=0;remote.activate()}
                else {tab=1;Task{await controller.handle(url:url)}}
            }
            .onChange(of:scenePhase){_,phase in
                if phase == .active {controller.refreshBattery();remote.foreground(true)}
                else if phase == .background {remote.foreground(false)}
            }
        }
    }
}
