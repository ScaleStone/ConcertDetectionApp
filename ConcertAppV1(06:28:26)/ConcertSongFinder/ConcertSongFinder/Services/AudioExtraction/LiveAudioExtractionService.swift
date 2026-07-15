import AVFoundation
import ConcertSongFinderCore
import Foundation

final class LiveAudioExtractionService: AudioExtractionService {
    private let temporaryDirectory: URL

    init(temporaryDirectory: URL) {
        self.temporaryDirectory = temporaryDirectory
    }

    func prepareAudio(for video: ConcertVideo) async throws -> PreparedAudio {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: video.localURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw ConcertSongFinderError.noAudioTrack
        }

        return try await extractAudioTrack(for: video, asset: asset, audioTrack: audioTrack)
    }

    private func extractAudioTrack(
        for video: ConcertVideo,
        asset: AVURLAsset,
        audioTrack: AVAssetTrack
    ) async throws -> PreparedAudio {
        try Task.checkCancellation()
        AppLog.analysis.info("Extracting original audio track for video \(video.id.uuidString, privacy: .public)")

        let outputURL = temporaryDirectory
            .appendingPathComponent("ConcertSongFinder-\(video.id.uuidString)-audio")
            .appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConcertSongFinderError.unsupportedMedia
        }

        let duration = try await asset.load(.duration)
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )

        let preset = await compatiblePreset(for: composition, outputFileType: .m4a)
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ConcertSongFinderError.unsupportedMedia
        }
        exportSession.directoryForTemporaryFiles = temporaryDirectory
        exportSession.shouldOptimizeForNetworkUse = false

        do {
            try await exportSession.export(to: outputURL, as: .m4a)
        } catch {
            AppLog.analysis.error("Audio track export failed for video \(video.id.uuidString, privacy: .public): \(String(describing: exportSession.error ?? error), privacy: .public)")
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw exportSession.error ?? error
        }

        let audioFile = try AVAudioFile(forReading: outputURL)
        AppLog.analysis.info("Prepared extracted audio for video \(video.id.uuidString, privacy: .public) at \(outputURL.lastPathComponent, privacy: .public)")
        return PreparedAudio(
            audioURL: outputURL,
            duration: video.duration,
            sampleRate: audioFile.processingFormat.sampleRate,
            channelCount: Int(audioFile.processingFormat.channelCount),
            sourceVideoID: video.id,
            temporaryFiles: [outputURL]
        )
    }

    private func compatiblePreset(for asset: AVAsset, outputFileType: AVFileType) async -> String {
        if await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough,
            with: asset,
            outputFileType: outputFileType
        ) {
            return AVAssetExportPresetPassthrough
        }

        return AVAssetExportPresetAppleM4A
    }
}
