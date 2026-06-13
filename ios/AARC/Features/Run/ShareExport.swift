import SwiftUI
import AVFoundation
import UIKit

/// Renders a ShareCard to a PNG image or an MP4 video. The video plays the
/// line's voice back while the quote highlights word-by-word — rendered
/// frame-by-frame with ImageRenderer, muxed with the cached audio via an
/// AVMutableComposition, exported as H.264 MP4 (shareable on any IM app).
@MainActor
enum ShareExport {
    static func image(_ model: ShareCardModel) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCardView(model: model, progress: 1))
        renderer.scale = 1
        return renderer.uiImage
    }

    /// Render the animated card + audio to an MP4. Returns the file URL.
    /// `audioURL` is the cached mp3 of the spoken line.
    static func video(model: ShareCardModel, audioURL: URL) async throws -> URL {
        let audioAsset = AVURLAsset(url: audioURL)
        let audioDur = try await audioAsset.load(.duration).seconds
        let dur = max(2.0, min(audioDur, 60)) + 0.8   // small outro
        let fps = 24.0

        // Video at 720-wide keeps frame rendering brisk; aspect preserved.
        let w = 720.0, h = (w / model.aspect).rounded()
        let size = CGSize(width: w, height: h)

        let silentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aarc-frames-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: silentURL)

        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mp4)
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(w), AVVideoHeightKey: Int(h),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(w),
                kCVPixelBufferHeightKey as String: Int(h),
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(dur * fps)
        let timescale: Int32 = 600
        for f in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            let t = Double(f) / fps
            // progress tracks the AUDIO portion; the outro holds at 1.
            let progress = min(t / max(audioDur, 0.1), 1)
            let renderer = ImageRenderer(content: ShareCardView(model: model, progress: progress))
            renderer.scale = w / 1080
            guard let cg = renderer.cgImage,
                  let buffer = pixelBuffer(from: cg, size: size) else { continue }
            let pts = CMTime(value: CMTimeValue(Double(f) / fps * Double(timescale)), timescale: timescale)
            adaptor.append(buffer, withPresentationTime: pts)
        }
        input.markAsFinished()
        await writer.finishWriting()

        // Mux the audio under the rendered video.
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silentURL)
        let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        if let srcV = try await videoAsset.loadTracks(withMediaType: .video).first {
            let vd = try await videoAsset.load(.duration)
            try vTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: srcV, at: .zero)
        }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        if let srcA = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let ad = try await audioAsset.load(.duration)
            try aTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: ad), of: srcA, at: .zero)
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aarc-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ShareError.exportFailed
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        await export.export()
        try? FileManager.default.removeItem(at: silentURL)
        guard export.status == .completed else { throw export.error ?? ShareError.exportFailed }
        return outURL
    }

    enum ShareError: Error { case exportFailed }

    private static func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
