import SwiftUI

@main
@MainActor
struct JarvisPhoneApp: App {
    @StateObject private var controller = PhoneController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(controller: controller)
                .preferredColorScheme(.dark)
                .tint(.cyan)
                .onOpenURL { url in
                    Task { await controller.handle(url: url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controller.refreshBattery() }
                }
        }
    }
}
