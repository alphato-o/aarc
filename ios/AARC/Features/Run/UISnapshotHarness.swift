import SwiftUI
import UIKit

/// Dev-only VISUAL harness for the in-run interactive cards (same env-gate
/// pattern as SummarySnapshotHarness): render them with controlled data to
/// PNGs, headless on the simulator, so layout is EYEBALLABLE before anything
/// is presented as shipped (the founder's sim-verify rule).
///
/// `AARC_UISNAP=1` at launch → writes PNGs to <Documents>/, then returns.
/// Pull with `xcrun simctl get_app_container booted club.aarun.AARC data`.
@MainActor
enum UISnapshotHarness {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AARC_UISNAP"] == "1"
    }

    static func run() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let slot = CGSize(width: 370, height: 330)   // the swap-zone's rough size

        // Venue cohort card: 3 big options + none.
        snap(InRunVenueConfirmCard(
                venues: VenueConfirm.uiTestSeed,
                onPick: { _ in }, onNone: {})
                .frame(width: slot.width, height: slot.height)
                .padding(12).background(Color(red: 0.06, green: 0.04, blue: 0.10)),
             to: dir.appendingPathComponent("uisnap-venue-cohort.png"))

        // Feedback card, unliked + liked (whole-card tap target, watermark heart).
        snap(InRunFeedbackCard(line: mockLine(liked: false), onHeart: {})
                .frame(width: slot.width, height: slot.height)
                .padding(12).background(Color(red: 0.06, green: 0.04, blue: 0.10)),
             to: dir.appendingPathComponent("uisnap-feedback-unliked.png"))
        snap(InRunFeedbackCard(line: mockLine(liked: true), onHeart: {})
                .frame(width: slot.width, height: slot.height)
                .padding(12).background(Color(red: 0.06, green: 0.04, blue: 0.10)),
             to: dir.appendingPathComponent("uisnap-feedback-liked.png"))

        // Nike archive rows: badge + real Nike title vs a normal AARC row.
        let nike = RunRecord(startedAt: Date(timeIntervalSince1970: 1729900000),
            personality: "roast_coach", runTypeRaw: "outdoor", source: "nike",
            externalId: "demo", importedTitle: "Marathon Race",
            cachedDistanceMeters: 42195, cachedDurationSeconds: 21475, cachedAvgPaceSecPerKm: 508, cachedEnergyKcal: 2371)
        let aarc = RunRecord(startedAt: Date(timeIntervalSince1970: 1729990000),
            personality: "roast_coach", runTypeRaw: "treadmill",
            cachedDistanceMeters: 10000, cachedDurationSeconds: 3600, cachedAvgPaceSecPerKm: 360, cachedEnergyKcal: 640)
        let rows = VStack(spacing: 0) {
            RunListRow(run: nike); Divider()
            RunListRow(run: aarc)
        }.padding(16).frame(width: 390).background(Color(red: 0.06, green: 0.04, blue: 0.10))
        snap(rows, to: dir.appendingPathComponent("uisnap-nike-rows.png"))

        NSLog("AARC_UISNAP wrote card PNGs to \(dir.path)")
    }

    private static func mockLine(liked: Bool) -> LiveSubtitleStore.Line {
        LiveSubtitleStore.Line(
            id: UUID(), text: "Another kilometre fed into the machine and the belt still owes you nothing, mate.",
            source: "script", priority: .coaching, voice: .ricky,
            startedAt: .now, isPlaying: false, estimatedTotalDwell: 20, liked: liked)
    }

    private static func snap(_ view: some View, to url: URL) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 2
        if let img = r.uiImage, let data = img.pngData() { try? data.write(to: url) }
    }
}
