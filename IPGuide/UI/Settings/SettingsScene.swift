import SwiftUI

struct SettingsScene: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label(String(localized: "Appearance"), systemImage: "eye") }
            AboutView()
                .tabItem { Label(String(localized: "About"), systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(width: 440, height: 320)
    }
}
