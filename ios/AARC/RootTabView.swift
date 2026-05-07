import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            RunHomeView()
                .tabItem { Label("Run", systemImage: "figure.run") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
    }
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
}
