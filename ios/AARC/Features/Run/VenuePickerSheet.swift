import SwiftUI

/// Treadmill venue picker, shown the moment the Treadmill slider fires.
///
/// Founder, 2026-10-13: "today i am in a middle of nowhere gym that i will not
/// visit for the second time... the venue selection should be right after the
/// run slider, list all options for me to quickly choose, give me the option
/// to type and search, and the option to choose precise venue information
/// not given."
///
/// So: every nearby candidate at once (not one at a time mid-run), a search
/// box that asks the proxy first (Amap in China) and Apple second, a free-text
/// row for a place no provider knows, and Skip. Whatever he picks is the
/// venue for this run and the in-run card never asks.
@MainActor
struct VenuePickerSheet: View {
    var onDone: () -> Void

    @State private var candidates: [String] = []
    @State private var loading = true
    @State private var query = ""
    @State private var searchResults: [String] = []
    @State private var searching = false
    @State private var provider = ""
    @State private var city: String?
    @State private var coord: (Double, Double)?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search or type the venue", text: $query)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, q in scheduleSearch(q) }
                    if searching { ProgressView() }
                    ForEach(searchResults, id: \.self) { name in
                        Button { pick(name) } label: { Label(name, systemImage: "magnifyingglass") }
                    }
                    let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if typed.count >= 2, !searchResults.contains(typed), !candidates.contains(typed) {
                        Button { pick(typed) } label: {
                            Label("Use \u{201C}\(typed)\u{201D}", systemImage: "pencil.line")
                        }
                    }
                } header: {
                    Text("Where are you?")
                } footer: {
                    if !provider.isEmpty { Text("Search via \(provider)") }
                }

                Section {
                    if loading {
                        HStack { ProgressView(); Text("Looking around…").foregroundStyle(.secondary) }
                    } else if candidates.isEmpty {
                        Text("Nothing found nearby. Type it above.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.self) { name in
                        Button { pick(name) } label: { Label(name, systemImage: "building.2") }
                    }
                } header: {
                    Text(city.map { "Nearby in \($0)" } ?? "Nearby")
                }
            }
            .navigationTitle("Treadmill venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { VenueConfirm.shared.skipForThisRun(); onDone() }
                }
            }
            .task { await loadNearby() }
        }
    }

    private func loadNearby() async {
        VenueConfirm.shared.resetForNewRun()
        if let v = await VenueLocator.shared.capture() {
            PlaceContext.shared.setTreadmillContext(coord: v.coord, city: v.city)
            candidates = v.venues
            city = v.city
            coord = (v.coord.latitude, v.coord.longitude)
        }
        loading = false
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            // Proxy first (Amap when configured), Apple as the fallback.
            if let remote = await AIClient.shared.venueSearch(trimmed, lat: coord?.0, lon: coord?.1, city: city),
               !remote.isEmpty {
                provider = "高德"
                if !Task.isCancelled { searchResults = Array(remote.prefix(12)) }
                return
            }
            let local = await VenueLocator.shared.search(trimmed)
            provider = "Apple Maps"
            if !Task.isCancelled { searchResults = Array(local.prefix(12)) }
        }
    }

    private func pick(_ name: String) {
        VenueConfirm.shared.preconfirm(name)
        onDone()
    }
}
