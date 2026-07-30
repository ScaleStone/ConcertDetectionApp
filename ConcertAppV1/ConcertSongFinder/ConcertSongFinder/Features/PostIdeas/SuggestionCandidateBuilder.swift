import AVFoundation
import ConcertSongFinderCore
import Foundation
import UIKit

/// Builds post-suggestion candidates from a concert's media (tasks 1.1–1.3,
/// 6.6).
///
/// - Candidate IDs are the deterministic `ConcertMediaGrouping.MediaLibraryItem`
///   ids ("video-<videoID>-<segmentID>" / "photo-<photoID>"), so backend
///   responses join back to on-device media safely.
/// - Keyframes: up to 4 per video spread across the segment, 1 per photo,
///   ~512px JPEG at 0.6 quality, re-encoded from raw pixels so no EXIF or
///   GPS metadata ever leaves the device.
/// - v2 metadata: audioClarity (Shazam matched-duration ratio — Shazam only
///   matches clean audio, so it doubles as an audio-quality proxy),
///   guest-feature detection (recognized artist differs from the headliner,
///   or setlist notes mention a guest), and segment bounds for clip ranges.
enum SuggestionCandidateBuilder {
    static let maxCandidates = 12
    static let maxFramesPerVideo = 4
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
        let headliner = concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName
        let selected = prioritize(items: items, occurrences: occurrences, headliner: headliner)
            .prefix(maxCandidates)

        var built: [BuiltCandidate] = []
        for item in selected {
            if let candidate = await buildCandidate(item: item, occurrences: occurrences, headliner: headliner) {
                built.append(candidate)
            }
        }
        AppLog.postIdeas.info("Built suggestion candidates count=\(built.count, privacy: .public) from items=\(items.count, privacy: .public)")
        return built
    }

    /// Orders items so the most promising candidates survive the cap:
    /// guest features first (cap-1 category must not get squeezed out),
    /// then rare songs, encores, identified videos, then photos.
    private static func prioritize(
        items: [ConcertMediaGrouping.MediaLibraryItem],
        occurrences: [SetlistOccurrence],
        headliner: String?
    ) -> [ConcertMediaGrouping.MediaLibraryItem] {
        func score(_ item: ConcertMediaGrouping.MediaLibraryItem) -> Int {
            let context = songContext(for: item, occurrences: occurrences, headliner: headliner)
            var value = 0
            if context.isGuestFeature { value += 16 }
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
        var isGuestFeature = false
        var featuredArtist: String?
        var setlistPosition: Int?
        var contextNotes: String?
    }

    /// Encore/position come from the matching setlist occurrence. Guest
    /// features are detected two ways: the recognized artist differs from
    /// the headliner (surprise guest song), or the setlist notes mention a
    /// guest ("with X"). A recognized song that is NOT on the setlist is
    /// additionally flagged rare when a setlist exists.
    private static func songContext(
        for item: ConcertMediaGrouping.MediaLibraryItem,
        occurrences: [SetlistOccurrence],
        headliner: String?
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
            if let notes = match.notes, notes.range(of: "with ", options: .caseInsensitive) != nil {
                context.isGuestFeature = true
                context.featuredArtist = guestName(fromNotes: notes)
            }
        } else if !occurrences.isEmpty {
            context.isRareSong = true
            context.contextNotes = "Recognized song not on the official setlist"
        }

        // Recognized artist differs from the headliner: a guest took the stage.
        if let artist = item.songArtist, let headliner,
           !TextNormalizer.normalizeText(headliner).isEmpty,
           TextNormalizer.normalizeText(artist) != TextNormalizer.normalizeText(headliner) {
            context.isGuestFeature = true
            context.featuredArtist = artist
        }
        return context
    }

    /// Pulls the guest name out of setlist notes like "with Rich Amiri".
    private static func guestName(fromNotes notes: String) -> String? {
        guard let range = notes.range(of: "with ", options: .caseInsensitive) else { return nil }
        let name = notes[range.upperBound...]
            .components(separatedBy: CharacterSet(charactersIn: ",;()"))
            .first?
            .trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// Shazam only produces matches from clean audio, so the fraction of the
    /// segment it matched is an honest 0-1 proxy for audio quality.
    private static func audioClarity(for segment: SongSegment?) -> Double? {
        guard let segment else { return nil }
        let length = max(segment.endTime - segment.startTime, 1)
        let ratio = segment.evidence.shazamMatchedDuration / length
        guard ratio > 0 else { return nil }
        return min(1, ratio)
    }

    private static func buildCandidate(
        item: ConcertMediaGrouping.MediaLibraryItem,
        occurrences: [SetlistOccurrence],
        headliner: String?
    ) async -> BuiltCandidate? {
        let context = songContext(for: item, occurrences: occurrences, headliner: headliner)
        let frames: [UIImage]
        let kind: String
        let duration: Double?
        var clarity: Double?
        var segmentStart: Double?
        var segmentEnd: Double?
        var videoDuration: Double?

        switch item.media {
        case .video(let video, let segment):
            kind = "video"
            let start = segment?.startTime ?? 0
            let end = segment?.endTime ?? video.duration
            duration = max(0, end - start)
            clarity = audioClarity(for: segment)
            segmentStart = start
            segmentEnd = end
            videoDuration = video.duration
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
            audioClarity: clarity,
            isGuestFeature: context.isGuestFeature,
            featuredArtist: context.featuredArtist,
            segmentStartSeconds: segmentStart,
            segmentEndSeconds: segmentEnd,
            videoDurationSeconds: videoDuration,
            frames: encoded
        )
        return BuiltCandidate(dto: dto, item: item, previewImage: frames.first)
    }

    /// Up to four frames spread evenly across the segment (just inside each
    /// edge so the first/last frames are not black transitions). More
    /// temporal coverage helps the model spot flashlight seas, mosh pits,
    /// and shakiness (frame-to-frame differences).
    private static func videoFrames(url: URL, start: TimeInterval, end: TimeInterval) async -> [UIImage] {
        let span = max(0, end - start)
        let inset = min(0.5, span / 4)
        let times: [TimeInterval]
        if span < 2 {
            times = [start + span / 2]
        } else {
            let usable = span - inset * 2
            times = (0..<maxFramesPerVideo).map { index in
                start + inset + usable * Double(index) / Double(maxFramesPerVideo - 1)
            }
        }

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
