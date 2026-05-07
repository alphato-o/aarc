import SwiftUI
import SwiftData

@main
struct AARCApp: App {
    private let phoneSession = PhoneSession()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(phoneSession)
                .preferredColorScheme(.dark)
                .task { phoneSession.activate() }
        }
        .modelContainer(PersistenceStore.shared.container)
    }
}
