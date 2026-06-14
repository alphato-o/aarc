import SwiftUI
import UIKit
import Photos

/// Share composer presented from the post-run summary. Previews the card,
/// lets the runner pick the centrepiece quote + format, and exports an image
/// or a voice-playback video to the system share sheet — the same output as
/// the web dashboard's share feature.
struct RunShareComposer: View {
    let target: ShareTarget
    @Environment(\.dismiss) private var dismiss
    @State private var store: RunSummaryStore

    /// Defaults to the live post-run store; History sharing injects a
    /// detached store seeded from a past run.
    init(target: ShareTarget, store: RunSummaryStore = .shared) {
        self.target = target
        _store = State(initialValue: store)
    }

    @State private var aspect = ShareCardModel.portrait
    @State private var quoteIdx = 0          // 0 = closing roast, 1… = hearted lines
    @State private var busy = false
    @State private var status = ""
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    // Route layout (outdoor): the baked map snapshot + colored trail.
    @State private var layout: Layout = .quote
    @State private var mapMode: RunMapView.ColorMode = .pace
    @State private var mapResult: ShareMap.Result?
    @State private var mapBuilding = false
    private enum Layout: String { case quote, route }

    private var isOutdoor: Bool { (store.summary?.isOutdoor ?? false) && (store.summary?.trail.count ?? 0) > 1 }

    @State private var preview: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // True WYSIWYG: show the exact rendered card image, not a
                    // scaled live view (scaleEffect kept the 1080pt layout
                    // bounds and rendered blank/clipped — the "wonky preview").
                    if let preview {
                        Image(uiImage: preview)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(radius: 12)
                    } else {
                        RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.3))
                            .aspectRatio(aspect, contentMode: .fit)
                            .overlay(ProgressView())
                    }
                    if isOutdoor { layoutPicker }
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
            .onAppear { regenPreview() }
            .onChange(of: aspect) { _, _ in if layout == .route { buildMapIfNeeded() } else { regenPreview() } }
            .onChange(of: quoteIdx) { _, _ in regenPreview() }
            .onChange(of: store.finalRoast) { _, _ in regenPreview() }
            .onChange(of: layout) { _, l in if l == .route { buildMapIfNeeded() } else { regenPreview() } }
            .onChange(of: mapMode) { _, _ in buildMapIfNeeded() }
        }
        .presentationDetents([.large])
    }

    private func regenPreview() {
        guard let m = model else { return }
        preview = ShareExport.image(m)
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
            quote: q.text.strippingAudioTags, who: q.who, heardAtKm: nil, aspect: aspect,
            mapImage: layout == .route ? mapResult?.image : nil,
            mapSegments: layout == .route ? (mapResult?.segments ?? []) : [],
            mapStart: layout == .route ? mapResult?.start : nil,
            mapFinish: layout == .route ? mapResult?.finish : nil)
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

    private var layoutPicker: some View {
        VStack(spacing: 8) {
            Picker("Layout", selection: $layout) {
                Text("Quote").tag(Layout.quote)
                Text("Route map").tag(Layout.route)
            }.pickerStyle(.segmented)
            if layout == .route {
                Picker("Trail color", selection: $mapMode) {
                    Text("Pace").tag(RunMapView.ColorMode.pace)
                    Text("HR").tag(RunMapView.ColorMode.hr)
                }.pickerStyle(.segmented)
                if mapBuilding { Text("Rendering map\u{2026}").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var formatPicker: some View {
        Picker("Format", selection: $aspect) {
            Text("Portrait").tag(ShareCardModel.portrait)
            Text("Square").tag(ShareCardModel.square)
        }.pickerStyle(.segmented)
    }

    /// Build the map snapshot (async) when the route layout / color / format
    /// changes, then refresh the preview.
    private func buildMapIfNeeded() {
        guard layout == .route, isOutdoor, let s = store.summary else { return }
        mapBuilding = true
        Task {
            let cardH = 1080 / aspect
            // Smaller map (~32% of card) so the quote is the hero.
            let res = await ShareMap.render(points: s.trail, mode: mapMode,
                                            width: 1080 - 152, height: (cardH * 0.32).rounded())
            mapResult = res
            mapBuilding = false
            regenPreview()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { shareImage() } label: {
                    Label("Share image", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.orange)
                Button { Task { await shareVideo() } } label: {
                    Label("Share video", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.orange)
            }
            HStack(spacing: 12) {
                Button { saveImageToPhotos() } label: {
                    Label("Save image", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { Task { await saveVideoToPhotos() } } label: {
                    Label("Save video", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }
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

    // MARK: save to Photos (add-only — we only ever write)

    private func saveImageToPhotos() {
        guard let m = model, let img = ShareExport.image(m) else { return }
        Task {
            let ok = await PhotoSaver.save(image: img)
            status = ok ? "Saved to Photos \u{2713}" : "Photos access denied."
        }
    }

    private func saveVideoToPhotos() async {
        guard let m = model else { return }
        let q = selectedQuote
        guard let voiceId = q.voiceId else { status = "No voice audio for this line."; return }
        busy = true; status = "Rendering voice video\u{2026}"
        await RemoteTTS.shared.prefetch(q.text, voiceId: voiceId)
        let key = AudioCache.key(voiceId: voiceId, text: q.text)
        guard let audioURL = await AudioCache.shared.url(forKey: key) else {
            busy = false; status = "Couldn\u{2019}t load the voice audio."; return
        }
        do {
            let url = try await ShareExport.video(model: m, audioURL: audioURL)
            let ok = await PhotoSaver.save(videoURL: url)
            busy = false; status = ok ? "Saved to Photos \u{2713}" : "Photos access denied."
        } catch {
            busy = false; status = "Video render failed."
        }
    }
}

/// Add-only Photos writes — request `.addOnly` authorization (no read).
enum PhotoSaver {
    static func save(image: UIImage) async -> Bool {
        guard await authorized() else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, _ in cont.resume(returning: ok) }
        }
    }
    static func save(videoURL: URL) async -> Bool {
        guard await authorized() else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }) { ok, _ in cont.resume(returning: ok) }
        }
    }
    private static func authorized() async -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if s == .authorized || s == .limited { return true }
        if s == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        }
        return false
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
