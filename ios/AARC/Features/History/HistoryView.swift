import SwiftUI

struct HistoryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No runs yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Completed runs will appear here. Start your first run from the Run tab.")
            )
            .navigationTitle("History")
        }
    }
}

#Preview {
    HistoryView()
        .preferredColorScheme(.dark)
}
