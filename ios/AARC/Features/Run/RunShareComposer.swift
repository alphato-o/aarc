import SwiftUI
import UIKit

/// Share composer presented from the post-run summary. Previews the card,
/// lets the runner pick the centrepiece quote + format, and exports an image
/// or a voice-playback video to the system share sheet — the same output as
/// the web dashboard's share feature.
struct RunShareComposer: View {
    let target: ShareTarget
    @Environment(\.dismiss) private var dismiss
    @State private var store = RunSummaryStore.shared

    @State private var aspect = ShareCardModel.portrait
    @State private var quoteIdx = 0          // 0 = closing roast, 1… = hearted lines
    @State private var busy = false
    @State private var status = ""
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let model = model {
                        ShareCardView(model: model)
                            .scaleEffect(previewScale(model), anchor: .top)
                            .frame(width: UIScreen.main.bounds.width - 40,
                                   height: (UIScreen.main.bounds.width - 40) / model.aspect)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(radius: 12)
                    }
                    quotePicker
                    formatPicker
                    actions
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showShare) { ActivityView(items: shareItems) }
        }
        .presentationDetents([.large])
    }

    // MARK: model

    private var hearted: [RunSummaryStore.HeartedLine] { store.summary?.hearted ?? [] }

    /// Quote options: the closing roast first, then each hearted line.
    private var quoteOptions: [(label: String, text: String, who: String, voiceId: String?)] {
        var out: [(String, String, String, String?)] = []
        if let roast = store.finalRoast {
            out.append(("Closing roast", roast,
                        store.finalRoastWho,
                        store.finalRoastWho == "jessica" ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId))
        }
        for l in hearted { out.append(("\u{2665} \(l.who): \(l.text.prefix(28))…", l.text, l.who, l.voiceId)) }
        if out.isEmpty { out.append(("Run", "Lace up. Get roasted. Run faster.", "", nil)) }
        return out
    }

    private var selectedQuote: (label: String, text: String, who: String, voiceId: String?) {
        let opts = quoteOptions
        // A hearted-line target preselects that line.
        if case .heartedLine(let l) = target,
           let i = opts.firstIndex(where: { $0.1 == l.text }) { return opts[i] }
        return opts[min(quoteIdx, opts.count - 1)]
    }

    private var model: ShareCardModel? {
        guard let s = store.summary else { return nil }
        let q = selectedQuote
        return ShareCardModel(
            date: s.startedAt.formatted(date: .abbreviated, time: .omitted),
            kpis: [
                ("Distance", String(format: "%.2f km", s.distanceMeters / 1000)),
                ("Time", RunSummaryStore.fmtDur(s.durationSeconds)),
                ("Pace", s.avgPaceSecPerKm > 0 ? RunSummaryStore.fmtPace(s.avgPaceSecPerKm) : "\u{2014}"),
                ("Avg HR", s.avgHR.map { "\(Int($0))" } ?? "\u{2014}"),
            ],
            speed: s.speedSeries, hr: s.hrSeries,
            quote: q.text, who: q.who, heardAtKm: nil, aspect: aspect)
    }

    private func previewScale(_ m: ShareCardModel) -> CGFloat {
        (UIScreen.main.bounds.width - 40) / 1080
    }

    // MARK: controls

    @ViewBuilder private var quotePicker: some View {
        if case .wholeRun = target, quoteOptions.count > 1 {
            Picker("Centrepiece", selection: $quoteIdx) {
                ForEach(Array(quoteOptions.enumerated()), id: \.offset) { i, o in
                    Text(o.label).tag(i)
                }
            }.pickerStyle(.menu)
        }
    }

    private var formatPicker: some View {
        Picker("Format", selection: $aspect) {
            Text("Portrait").tag(ShareCardModel.portrait)
            Text("Square").tag(ShareCardModel.square)
        }.pickerStyle(.segmented)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { shareImage() } label: {
                Label("Image", systemImage: "photo").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(.orange)
            Button { Task { await shareVideo() } } label: {
                Label("Video", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(.orange)
        }
        .controlSize(.large)
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
    }

    // MARK: export

    private func shareImage() {
        guard let m = model, let img = ShareExport.image(m) else { return }
        shareItems = [img]; showShare = true
    }

    private func shareVideo() async {
        guard let m = model else { return }
        let q = selectedQuote
        guard let voiceId = q.voiceId else {
            status = "No voice audio for this line."; return
        }
        busy = true; status = "Rendering voice video\u{2026}"
        // Make sure the line's audio is cached, then render against it.
        await RemoteTTS.shared.prefetch(q.text, voiceId: voiceId)
        let key = AudioCache.key(voiceId: voiceId, text: q.text)
        guard let audioURL = await AudioCache.shared.url(forKey: key) else {
            busy = false; status = "Couldn\u{2019}t load the voice audio."; return
        }
        do {
            let url = try await ShareExport.video(model: m, audioURL: audioURL)
            busy = false; status = ""
            shareItems = [url]; showShare = true
        } catch {
            busy = false; status = "Video render failed."
        }
    }
}

/// UIActivityViewController bridge.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
