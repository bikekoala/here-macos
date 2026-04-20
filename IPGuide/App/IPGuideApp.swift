import SwiftUI

@main
struct IPGuideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsScene()
                .environment(appDelegate.environment.settings)
                .environment(appDelegate.environment)
        }
    }
}
