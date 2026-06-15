import SwiftUI
import UIKit
import Photos
import AARCKit

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
                            .overlay(alignment: .top) {
                                if mapBuilding {
                                    Text("Loading map\u{2026}")
                                        .font(.caption2).foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .padding(.top, 24)
                                }
                            }
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
            .onChange(of: mapMode) { _, _ in if layout == .route { buildMapIfNeeded() } }
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
            date: Self.shareDate(s.startedAt),
            kpis: [
                ("Distance", Self.fmtDist(s.distanceMeters)),
                ("Time", Self.fmtDur(s.durationSeconds)),
                ("Pace", Self.fmtPace(s.avgPaceSecPerKm)),
                ("Avg HR", s.avgHR.map { "\(Int($0.rounded())) bpm" } ?? "\u{2014}"),
            ],
            speed: s.speedSeries, hr: s.hrSeries,
            quote: q.text.strippingAudioTags, who: q.who, heardAtKm: nil, aspect: aspect,
            mapImage: layout == .route ? mapResult?.image : nil,
            mapPoints: layout == .route ? (mapResult?.points ?? []) : [],
            mapColors: layout == .route ? (mapResult?.colors ?? []) : [])
    }

    // MARK: web-identical KPI / date formatting
    // These mirror proxy/src/routes/dashboardApp.ts (fmtDist / fmtDur / fmtPace
    // / shareDateLabel) char-for-char so the iOS card reads exactly like the
    // dashboard: "2.63 km", "15m39s", "5:58/km", "150 bpm", "Mon, Jun 15, 2026".

    private static func fmtDist(_ m: Double) -> String {
        guard m.isFinite, m > 0 else { return "\u{2014}" }
        return m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m.rounded())) m"
    }
    private static func fmtDur(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "\u{2014}" }
        let m = Int(sec / 60), s = Int((sec - Double(m) * 60).rounded())
        return "\(m)m\(s < 10 ? "0" : "")\(s)s"
    }
    private static func fmtPace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "\u{2014}" }
        let m = Int(secPerKm / 60), s = Int((secPerKm - Double(m) * 60).rounded())
        return "\(m):\(s < 10 ? "0" : "")\(s)/km"
    }
    private static func shareDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d, yyyy"   // "Mon, Jun 15, 2026"
        return f.string(from: d)
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
                if mapBuilding { Text("Loading map\u{2026}").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var formatPicker: some View {
        Picker("Format", selection: $aspect) {
            Text("Portrait").tag(ShareCardModel.portrait)
            Text("Square").tag(ShareCardModel.square)
        }.pickerStyle(.segmented)
    }

    /// Build the route map (fetch + stitch AutoNavi tiles, project the trail),
    /// then refresh the preview. Falls back to the quote layout if the tiles
    /// can't be fetched (offline).
    private func buildMapIfNeeded() {
        guard layout == .route, isOutdoor, let s = store.summary else { return }
        mapBuilding = true
        mapResult = nil
        Task {
            let cardH = 1080 / aspect
            // Route region (~30% of card) + a bottom band that holds the white
            // KPI overlay; the route is fit ABOVE the band so they never collide.
            // Tiles don't touch D1/R2 — use the failover-aware endpoint, NOT the
            // CF-pinned one (CF crawls in China; the gateway serves tiles ~2s).
            let routeH = (cardH * 0.30).rounded()
            let band = ShareCardView.mapKpiBand
            let res = await ShareMap.render(points: s.trail, mode: mapMode,
                                            width: 1080 - 152, height: routeH + band,
                                            padBottom: band,
                                            tileBase: Config.apiBaseURL.absoluteString)
            mapResult = res
            mapBuilding = false
            if res == nil {
                layout = .quote
                status = "Couldn\u{2019}t load the map (offline?) — using the quote layout."
            }
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
        .disabled(busy || mapBuilding)
        .overlay { if busy { ProgressView() } }
    }

    // MARK: export

    /// Filesystem-safe run name for exported files (matches the dashboard).
    private var fileSlug: String {
        guard let s = store.summary else { return "aarc-run" }
        return RunTitleGenerator.fileName(forRunId: s.runId, date: s.startedAt,
                                          runType: s.isOutdoor ? .outdoor : .treadmill)
    }

    private func shareImage() {
        guard let m = model, let img = ShareExport.image(m) else { return }
        // Share a named file (not a bare UIImage) so the run name is the filename.
        if let data = img.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileSlug).png")
            try? data.write(to: url)
            shareItems = FileManager.default.fileExists(atPath: url.path) ? [url] : [img]
        } else {
            shareItems = [img]
        }
        showShare = true
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
            shareItems = [renamed(url, to: "\(fileSlug).mp4")]; showShare = true
        } catch {
            busy = false; status = "Video render failed."
        }
    }

    /// Move an exported temp file to a named one (so the share sheet shows the
    /// run name); falls back to the original on failure.
    private func renamed(_ url: URL, to name: String) -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: url, to: dst); return dst }
        catch { return url }
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
