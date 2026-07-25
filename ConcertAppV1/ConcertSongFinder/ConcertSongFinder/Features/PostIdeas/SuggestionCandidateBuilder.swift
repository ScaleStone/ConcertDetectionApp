import AVFoundation
import ConcertSongFinderCore
import Foundation
import UIKit

/// Builds post-suggestion candidates from a concert's media (task 1.1–1.3).
///
/// - Candidate IDs are the deterministic `ConcertMediaGrouping.MediaLibraryItem`
///   ids ("video-<videoID>-<segmentID>" / "photo-<photoID>"), so backend
///   responses join back to on-device media safely.
/// - Keyframes: up to 3 per video (segment start/mid/end), 1 per photo,
///   ~512px JPEG at 0.6 quality, re-encoded from raw pixels so no EXIF or
///   GPS metadata ever leaves the device.
/// - Caps mirror the backend: ≤12 candidates, ≤3 frames each.
enum SuggestionCandidateBuilder {
    static let maxCandidates = 12
    static let maxFramePixels: CGFloat = 512
    static let jpegQuality: CGFloat = 0.6
    /// Backend rejects frames above this base64 length; skip rather than fail.
    static let maxFrameBase64Chars = 400_000

    struct BuiltCandidate {
        let dto: SuggestionCandidateDTO
        let item: ConcertMediaGrouping.MediaLibraryItem
        /// First keyframe decoded for UI thumbnails (avoids regenerating).
        let previewImage: UIImage?
    }

    static func build(for concert: ConcertRecord) async -> [BuiltCandidate] {
        let items = ConcertMediaGrouping.libraryItems(
            videos: concert.videos,
            photos: concert.photos,
            setlist: concert.selectedSetlist
        )
        let occurrences = concert.selectedSetlist?.occurrences ?? []
        let selected = prioritize(items: items, occurrences: occurrences).prefix(maxCandidates)

        var built: [BuiltCandidate] = []
        for item in selected {
            if let candidate = await buildCandidate(item: item, occurrences: occurrences) {
                built.append(candidate)
            }
        }
        AppLog.postIdeas.info("Built suggestion candidates count=\(built.count, privacy: .public) from items=\(items.count, privacy: .public)")
        return built
    }

    /// Orders items so the most promising candidates survive the cap:
    /// rare (off-setlist) songs, then encores, then identified videos,
    /// identified photos, and unknowns last.
    private static func prioritize(
        items: [ConcertMediaGrouping.MediaLibraryItem],
        occurrences: [SetlistOccurrence]
    ) -> [ConcertMediaGrouping.MediaLibraryItem] {
        func score(_ item: ConcertMediaGrouping.MediaLibraryItem) -> Int {
            let context = songContext(for: item, occurrences: occurrences)
            var value = 0
            if context.isRareSong { value += 8 }
            if context.isEncore { value += 4 }
            if item.songTitle != nil { value += 2 }
            if case .video = item.media { value += 1 }
            return value
        }
        return items.sorted { score($0) > score($1) }
    }

    private struct SongContext {
        var isEncore = false
        var isRareSong = false
        var setlistPosition: Int?
        var contextNotes: String?
    }

    /// Encore/position come from the matching setlist occurrence. A reliably
    /// identified song that is NOT on the setlist is flagged rare (surprise
    /// song, cover, or guest moment) — but only when a setlist exists.
    private static func songContext(
        for item: ConcertMediaGrouping.MediaLibraryItem,
        occurrences: [SetlistOccurrence]
    ) -> SongContext {
        var context = SongContext()
        guard let title = item.songTitle else { return context }

        let itemTitle = TextNormalizer.comparableSongTitle(title)
        let match = occurrences.first { occurrence in
            TextNormalizer.comparableSongTitle(occurrence.title) == itemTitle
        }
        if let match {
            context.isEncore = match.isEncore
            context.setlistPosition = match.overallIndex
            context.contextNotes = match.notes
        } else if !occurrences.isEmpty {
            context.isRareSong = true
            context.contextNotes = "Recognized song not on the official setlist"
        }
        return context
    }

    private static func buildCandidate(
        item: ConcertMediaGrouping.MediaLibraryItem,
        occurrences: [SetlistOccurrence]
    ) async -> BuiltCandidate? {
        let context = songContext(for: item, occurrences: occurrences)
        let frames: [UIImage]
        let kind: String
        let duration: Double?

        switch item.media {
        case .video(let video, let segment):
            kind = "video"
            let start = segment?.startTime ?? 0
            let end = segment?.endTime ?? video.duration
            duration = max(0, end - start)
            frames = await videoFrames(url: video.localURL, start: start, end: end)
        case .photo(let photo):
            kind = "photo"
            duration = nil
            frames = await photoFrame(url: photo.localURL).map { [$0] } ?? []
        }

        guard !frames.isEmpty else {
            AppLog.postIdeas.error("Skipping candidate with no extractable frames id=\(item.id, privacy: .public)")
            return nil
        }

        let encoded = frames.compactMap(encodeFrame).filter { $0.count <= maxFrameBase64Chars }
        guard !encoded.isEmpty else { return nil }

        let dto = SuggestionCandidateDTO(
            id: item.id,
            kind: kind,
            songTitle: item.songTitle,
            artist: item.songArtist,
            isEncore: context.isEncore,
            isRareSong: context.isRareSong,
            setlistPosition: context.setlistPosition,
            durationSeconds: duration,
            contextNotes: context.contextNotes,
            frames: encoded
        )
        return BuiltCandidate(dto: dto, item: item, previewImage: frames.first)
    }

    /// Three frames spread across the segment (just inside each edge so the
    /// first/last frames are not black transitions).
    private static func videoFrames(url: URL, start: TimeInterval, end: TimeInterval) async -> [UIImage] {
        let span = max(0, end - start)
        let inset = min(0.5, span / 4)
        let times = span < 2
            ? [start + span / 2]
            : [start + inset, start + span / 2, end - inset]

        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxFramePixels, height: maxFramePixels)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            var images: [UIImage] = []
            for seconds in times {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    images.append(UIImage(cgImage: cgImage))
                }
            }
            return images
        }.value
    }

    private static func photoFrame(url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxFramePixels
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            // UIImage(cgImage:) holds raw pixels only; re-encoding below
            // produces JPEG data with no EXIF/GPS from the original file.
            return UIImage(cgImage: cgImage)
        }.value
    }

    private static func encodeFrame(_ image: UIImage) -> String? {
        image.jpegData(compressionQuality: jpegQuality)?.base64EncodedString()
    }
}
