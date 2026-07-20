import Foundation
import os

private enum CoreLog {
    static let mediaClassification = Logger(subsystem: "ConcertSongFinderCore", category: "media-classification")
}

public struct MediaClassificationConfiguration: Codable, Hashable {
    public var exactMatchPadding: TimeInterval
    public var nearbyTolerance: TimeInterval
    public var sameSongGapTolerance: TimeInterval

    public init(
        exactMatchPadding: TimeInterval = 2,
        nearbyTolerance: TimeInterval = 180,
        sameSongGapTolerance: TimeInterval = 480
    ) {
        self.exactMatchPadding = exactMatchPadding
        self.nearbyTolerance = nearbyTolerance
        self.sameSongGapTolerance = sameSongGapTolerance
    }

    public static let `default` = MediaClassificationConfiguration()
}

public final class DefaultMediaClassificationService {
    public init() {}

    public func classify(
        record: AnalysisRecord,
        configuration: MediaClassificationConfiguration = .default
    ) -> AnalysisRecord {
        var updated = record
        let setlistContext = SetlistContext(setlist: record.selectedSetlist)
        let anchors = absoluteSongAnchors(from: record, setlistContext: setlistContext)
        let concertRange = concertTimeRange(from: record.videos)
        CoreLog.mediaClassification.info("Core media classification started record=\(record.id.uuidString, privacy: .public) videos=\(record.videos.count, privacy: .public) photos=\(record.photos.count, privacy: .public) anchors=\(anchors.count, privacy: .public) setlistOccurrences=\(setlistContext.occurrences.count, privacy: .public) hasConcertRange=\((concertRange != nil), privacy: .public) exactPadding=\(configuration.exactMatchPadding, privacy: .public) nearbyTolerance=\(configuration.nearbyTolerance, privacy: .public) sameSongGapTolerance=\(configuration.sameSongGapTolerance, privacy: .public)")
        CoreLog.mediaClassification.info("Core temporal setlist context record=\(record.id.uuidString, privacy: .public) selectedSetlistID=\(record.selectedSetlist?.id ?? "nil", privacy: .public) selectedArtist=\(record.selectedSetlist?.artistName ?? "nil", privacy: .public) selectedVenue=\(record.selectedSetlist?.venueName ?? "nil", privacy: .public) occurrenceCount=\(record.selectedSetlist?.occurrences.count ?? 0, privacy: .public) occurrencePreview=\(self.setlistOccurrencePreview(record.selectedSetlist?.occurrences ?? []), privacy: .public)")
        if setlistContext.occurrences.isEmpty {
            CoreLog.mediaClassification.warning("Core temporal classification cannot infer bounded song options because selected setlist occurrences are empty record=\(record.id.uuidString, privacy: .public) selectedSetlistID=\(record.selectedSetlist?.id ?? "nil", privacy: .public) anchors=\(anchors.count, privacy: .public)")
        }

        for photoIndex in updated.photos.indices {
            updated.photos[photoIndex] = classifyPhotoTiming(updated.photos[photoIndex], concertRange: concertRange)
        }

        guard !anchors.isEmpty else {
            CoreLog.mediaClassification.info("Core media classification skipped because no reliable song anchors were available record=\(record.id.uuidString, privacy: .public)")
            return updated
        }

        for photoIndex in updated.photos.indices {
            updated.photos[photoIndex] = classifyPhoto(
                updated.photos[photoIndex],
                anchors: anchors,
                configuration: configuration,
                setlistContext: setlistContext
            )
        }

        for videoIndex in updated.videos.indices {
            updated.videos[videoIndex] = classifyUnknownVideoSegments(
                updated.videos[videoIndex],
                anchors: anchors,
                setlistContext: setlistContext
            )
        }

        let inferredPhotoCount = updated.photos.filter { $0.primaryCandidate != nil || !$0.evidence.boundedCandidateOptions.isEmpty }.count
        let inferredUnknownVideoSegments = updated.videos.flatMap(\.segments).filter { $0.evidence.neighboringVideoSupport != nil || !$0.evidence.boundedCandidateOptions.isEmpty }.count
        CoreLog.mediaClassification.info("Core media classification finished record=\(record.id.uuidString, privacy: .public) inferredPhotos=\(inferredPhotoCount, privacy: .public) inferredUnknownVideoSegments=\(inferredUnknownVideoSegments, privacy: .public)")
        return updated
    }

    private func classifyPhotoTiming(
        _ photo: ConcertPhoto,
        concertRange: ClosedRange<Date>?
    ) -> ConcertPhoto {
        var updated = photo
        guard let createdAt = photo.createdAt, let concertRange else {
            updated.concertTiming = .unknown
            CoreLog.mediaClassification.info("Photo concert timing unknown photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) hasTimestamp=\((photo.createdAt != nil), privacy: .public) hasConcertRange=\((concertRange != nil), privacy: .public)")
            return updated
        }

        if createdAt < concertRange.lowerBound {
            updated.concertTiming = .beforeConcert
        } else if createdAt > concertRange.upperBound {
            updated.concertTiming = .afterConcert
        } else {
            updated.concertTiming = .duringConcert
        }

        CoreLog.mediaClassification.info("Photo concert timing classified photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) timing=\(updated.concertTiming?.rawValue ?? "nil", privacy: .public) createdAt=\(createdAt.ISO8601Format(), privacy: .public) concertStart=\(concertRange.lowerBound.ISO8601Format(), privacy: .public) concertEnd=\(concertRange.upperBound.ISO8601Format(), privacy: .public)")
        return updated
    }

    private func classifyPhoto(
        _ photo: ConcertPhoto,
        anchors: [AbsoluteSongAnchor],
        configuration: MediaClassificationConfiguration,
        setlistContext: SetlistContext
    ) -> ConcertPhoto {
        guard let createdAt = photo.createdAt else {
            CoreLog.mediaClassification.info("Photo classification skipped missing timestamp photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public)")
            return photo
        }

        if photo.concertTiming == .beforeConcert || photo.concertTiming == .afterConcert {
            var updated = photo
            updated.classificationStatus = .unknown
            updated.primaryCandidate = nil
            updated.alternativeCandidates = []
            updated.assignedVideoID = nil
            updated.assignedSegmentID = nil
            updated.evidence.boundedCandidateOptions = []
            updated.evidence.neighboringVideoSupport = nil
            updated.evidence.classificationSource = nil
            CoreLog.mediaClassification.info("Photo song classification skipped outside concert photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) timing=\(photo.concertTiming?.rawValue ?? "nil", privacy: .public)")
            return updated
        }

        var updated = photo
        if let exact = anchors.first(where: { $0.contains(createdAt, padding: configuration.exactMatchPadding) }) {
            assign(anchor: exact, to: &updated, status: exact.status, score: 1, reason: "Photo timestamp falls inside this song segment")
            logPhotoClassification(updated, reason: "exact-segment")
            return updated
        }

        if let range = boundedCandidateRange(for: createdAt, anchors: anchors, setlistContext: setlistContext) {
            assign(range: range, to: &updated)
            logTemporalRange(range, target: "photo", id: photo.id.uuidString, timestamp: createdAt)
            logPhotoClassification(updated, reason: "bounded-temporal-range")
            return updated
        }

        updated.classificationStatus = .unknown
        updated.primaryCandidate = nil
        updated.alternativeCandidates = []
        updated.assignedVideoID = nil
        updated.assignedSegmentID = nil
        updated.evidence.boundedCandidateOptions = []
        CoreLog.mediaClassification.info("Photo classification unresolved photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) createdAt=\(createdAt.ISO8601Format(), privacy: .public) reason=\(self.temporalRangeFailureReason(for: createdAt, anchors: anchors, setlistContext: setlistContext), privacy: .public)")
        return updated
    }

    private func classifyUnknownVideoSegments(
        _ video: ConcertVideo,
        anchors: [AbsoluteSongAnchor],
        setlistContext: SetlistContext
    ) -> ConcertVideo {
        guard let videoStart = video.createdAt else {
            if video.segments.contains(where: { $0.status == .unknown }) {
                CoreLog.mediaClassification.info("Unknown video segment classification skipped missing timestamp video=\(video.id.uuidString, privacy: .public) file=\(video.fileName, privacy: .public)")
            }
            return video
        }
        var updated = video

        for segmentIndex in updated.segments.indices where updated.segments[segmentIndex].status == .unknown {
            let segment = updated.segments[segmentIndex]
            let segmentStart = videoStart.addingTimeInterval(segment.startTime)
            let segmentEnd = videoStart.addingTimeInterval(segment.endTime)
            let midpoint = segmentStart.addingTimeInterval(segmentEnd.timeIntervalSince(segmentStart) / 2)

            if let range = boundedCandidateRange(for: midpoint, anchors: anchors, setlistContext: setlistContext) {
                updated.segments[segmentIndex] = inferredSegment(from: segment, range: range)
                logTemporalRange(range, target: "unknown-video-segment", id: segment.id.uuidString, timestamp: midpoint)
                logUnknownSegmentClassification(updated.segments[segmentIndex], video: updated, reason: "bounded-temporal-range")
            } else {
                CoreLog.mediaClassification.info("Unknown video segment remained unresolved video=\(updated.id.uuidString, privacy: .public) file=\(updated.fileName, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) midpoint=\(midpoint.ISO8601Format(), privacy: .public) reason=\(self.temporalRangeFailureReason(for: midpoint, anchors: anchors, setlistContext: setlistContext), privacy: .public)")
            }
        }

        return updated
    }

    private func logPhotoClassification(_ photo: ConcertPhoto, reason: String) {
        CoreLog.mediaClassification.info("Photo classified photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) status=\(photo.classificationStatus.rawValue, privacy: .public) title=\(photo.primaryCandidate?.song.title ?? "nil", privacy: .public) artist=\(photo.primaryCandidate?.song.artist ?? "nil", privacy: .public) support=\(photo.evidence.neighboringVideoSupport ?? -1, privacy: .public) boundedOptions=\(photo.evidence.boundedCandidateOptions.count, privacy: .public) assignedVideo=\(photo.assignedVideoID?.uuidString ?? "nil", privacy: .public) assignedSegment=\(photo.assignedSegmentID?.uuidString ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func logUnknownSegmentClassification(_ segment: SongSegment, video: ConcertVideo, reason: String) {
        CoreLog.mediaClassification.info("Unknown video segment inferred video=\(video.id.uuidString, privacy: .public) file=\(video.fileName, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) status=\(segment.status.rawValue, privacy: .public) title=\(segment.primaryCandidate?.song.title ?? "nil", privacy: .public) artist=\(segment.primaryCandidate?.song.artist ?? "nil", privacy: .public) support=\(segment.evidence.neighboringVideoSupport ?? -1, privacy: .public) boundedOptions=\(segment.evidence.boundedCandidateOptions.count, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func logTemporalRange(_ range: BoundedSongRange, target: String, id: String, timestamp: Date) {
        let titles = range.options.map { $0.song.title }.joined(separator: " | ")
        CoreLog.mediaClassification.info("Temporal bounded options target=\(target, privacy: .public) id=\(id, privacy: .public) timestamp=\(timestamp.ISO8601Format(), privacy: .public) lowerIndex=\(range.lowerOverallIndex, privacy: .public) upperIndex=\(range.upperOverallIndex, privacy: .public) optionCount=\(range.options.count, privacy: .public) suggestion=\(range.suggestedCandidate?.song.title ?? "nil", privacy: .public) reason=\(range.reason, privacy: .public) options=\(titles, privacy: .public)")
    }

    private func assign(
        anchor: AbsoluteSongAnchor,
        to photo: inout ConcertPhoto,
        status: SegmentStatus,
        score: Double,
        reason: String
    ) {
        let candidate = anchor.occurrence.map {
            makeCandidate(from: $0, score: score, confidenceLabel: confidenceLabel(for: status), reason: reason)
        } ?? SongCandidate(
            song: anchor.candidate.song,
            setlistOccurrenceID: anchor.candidate.setlistOccurrenceID,
            evidenceScore: score,
            confidenceLabel: confidenceLabel(for: status),
            reasons: [reason]
        )
        photo.classificationStatus = status
        photo.primaryCandidate = candidate
        photo.alternativeCandidates = []
        photo.assignedVideoID = anchor.videoID
        photo.assignedSegmentID = anchor.segmentID
        photo.evidence.neighboringVideoSupport = score
        photo.evidence.boundedCandidateOptions = anchor.occurrence == nil ? [] : [candidate]
        photo.evidence.classificationSource = .temporalPositioning
    }

    private func assign(range: BoundedSongRange, to photo: inout ConcertPhoto) {
        photo.classificationStatus = range.status
        photo.primaryCandidate = range.suggestedCandidate
        photo.alternativeCandidates = []
        photo.assignedVideoID = range.suggestedAnchor?.videoID
        photo.assignedSegmentID = range.suggestedAnchor?.segmentID
        photo.evidence.neighboringVideoSupport = range.score
        photo.evidence.boundedCandidateOptions = range.options
        photo.evidence.classificationSource = .temporalPositioning
    }

    private func inferredSegment(from segment: SongSegment, range: BoundedSongRange) -> SongSegment {
        var updated = segment
        updated.status = range.status
        updated.primaryCandidate = range.suggestedCandidate
        updated.alternativeCandidates = []
        updated.evidence.neighboringVideoSupport = range.score
        updated.evidence.boundedCandidateOptions = range.options
        updated.evidence.classificationSource = .temporalPositioning
        return updated
    }

    private func confidenceLabel(for status: SegmentStatus) -> ConfidenceLabel {
        switch status {
        case .identified, .userConfirmed: .strong
        case .likely: .likely
        case .possible, .transition: .possible
        case .speech, .unknown: .insufficient
        }
    }

    private func absoluteSongAnchors(from record: AnalysisRecord, setlistContext: SetlistContext) -> [AbsoluteSongAnchor] {
        record.videos.flatMap { video -> [AbsoluteSongAnchor] in
            guard let videoStart = video.createdAt else { return [] }
            return video.segments.compactMap { segment in
                guard let candidate = segment.primaryCandidate,
                      [.identified, .likely, .userConfirmed].contains(segment.status) else {
                    return nil
                }

                let occurrence = setlistContext.resolveOccurrence(for: candidate)
                if let occurrence {
                    CoreLog.mediaClassification.info("Song anchor resolved to setlist occurrence video=\(video.id.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) title=\(candidate.song.title, privacy: .public) artist=\(candidate.song.artist, privacy: .public) occurrenceID=\(occurrence.id, privacy: .public) overallIndex=\(occurrence.overallIndex, privacy: .public)")
                } else {
                    CoreLog.mediaClassification.info("Song anchor has no setlist occurrence video=\(video.id.uuidString, privacy: .public) segment=\(segment.id.uuidString, privacy: .public) title=\(candidate.song.title, privacy: .public) artist=\(candidate.song.artist, privacy: .public) setlistOccurrenceID=\(candidate.setlistOccurrenceID ?? "nil", privacy: .public) setlistOccurrenceCount=\(setlistContext.occurrences.count, privacy: .public) normalizedTitle=\(TextNormalizer.normalizeSongTitle(candidate.song.title), privacy: .public) normalizedArtist=\(TextNormalizer.normalizeText(candidate.song.artist), privacy: .public)")
                }

                return AbsoluteSongAnchor(
                    videoID: video.id,
                    segmentID: segment.id,
                    start: videoStart.addingTimeInterval(segment.startTime),
                    end: videoStart.addingTimeInterval(segment.endTime),
                    candidate: candidate,
                    occurrence: occurrence,
                    status: segment.status
                )
            }
        }
        .sorted { $0.start < $1.start }
    }

    private func concertTimeRange(from videos: [ConcertVideo]) -> ClosedRange<Date>? {
        let ranges = videos.compactMap { video -> ClosedRange<Date>? in
            guard let start = video.createdAt else { return nil }
            let end = start.addingTimeInterval(max(video.duration, 0))
            return start...end
        }
        guard let start = ranges.map(\.lowerBound).min(),
              let end = ranges.map(\.upperBound).max() else {
            return nil
        }
        return start...end
    }

    private func boundedCandidateRange(
        for date: Date,
        anchors: [AbsoluteSongAnchor],
        setlistContext: SetlistContext
    ) -> BoundedSongRange? {
        guard let setlistBounds = setlistContext.overallIndexBounds else { return nil }

        let previous = anchors.last(where: { $0.end <= date && $0.occurrence != nil })
        let next = anchors.first(where: { $0.start >= date && $0.occurrence != nil })
        let previousIndex = previous?.occurrence?.overallIndex
        let nextIndex = next?.occurrence?.overallIndex

        let lower: Int
        let upper: Int
        let suggestedAnchor: AbsoluteSongAnchor?
        let reason: String

        switch (previousIndex, nextIndex) {
        case let (.some(previousIndex), .some(nextIndex)):
            lower = min(previousIndex, nextIndex)
            upper = max(previousIndex, nextIndex)
            let previousDistance = previous.map { date.timeIntervalSince($0.end) } ?? .greatestFiniteMagnitude
            let nextDistance = next.map { $0.start.timeIntervalSince(date) } ?? .greatestFiniteMagnitude
            suggestedAnchor = previousDistance <= nextDistance ? previous : next
            reason = "Bounded by previous and next setlist anchors"
        case let (.some(previousIndex), .none):
            lower = previousIndex
            upper = setlistBounds.upperBound
            suggestedAnchor = previous
            reason = "Bounded by previous setlist anchor and setlist end"
        case let (.none, .some(nextIndex)):
            lower = setlistBounds.lowerBound
            upper = nextIndex
            suggestedAnchor = next
            reason = "Bounded by setlist start and next setlist anchor"
        case (.none, .none):
            return nil
        }

        let options = setlistContext.candidates(in: lower...upper, reason: reason)
        guard !options.isEmpty else { return nil }

        let suggestedCandidate = options.count == 1
            ? options[0]
            : option(for: suggestedAnchor?.occurrence, in: options)
        let status: SegmentStatus = options.count == 1 ? .likely : .possible
        let score = options.count == 1 ? 0.95 : max(0.35, 1 / Double(options.count))

        return BoundedSongRange(
            lowerOverallIndex: lower,
            upperOverallIndex: upper,
            options: options,
            suggestedAnchor: suggestedAnchor,
            suggestedCandidate: suggestedCandidate,
            status: status,
            score: score,
            reason: reason
        )
    }

    private func temporalRangeFailureReason(
        for date: Date,
        anchors: [AbsoluteSongAnchor],
        setlistContext: SetlistContext
    ) -> String {
        let previous = anchors.last(where: { $0.end <= date && $0.occurrence != nil })
        let next = anchors.first(where: { $0.start >= date && $0.occurrence != nil })
        return "no bounded setlist range hasSetlist=\(!setlistContext.occurrences.isEmpty) previous=\(previous?.candidate.song.title ?? "nil") previousIndex=\(previous?.occurrence?.overallIndex.description ?? "nil") next=\(next?.candidate.song.title ?? "nil") nextIndex=\(next?.occurrence?.overallIndex.description ?? "nil")"
    }

    private func option(for occurrence: SetlistOccurrence?, in options: [SongCandidate]) -> SongCandidate? {
        guard let occurrence else { return nil }
        return options.first { $0.setlistOccurrenceID == occurrence.id }
    }

    private func setlistOccurrencePreview(_ occurrences: [SetlistOccurrence]) -> String {
        let preview = occurrences.prefix(12).map { occurrence in
            "#\(occurrence.overallIndex):\(occurrence.title) by \(occurrence.artist) id=\(occurrence.id)"
        }
        let suffix = occurrences.count > 12 ? " ... +\(occurrences.count - 12) more" : ""
        return preview.joined(separator: " | ") + suffix
    }

    private func makeCandidate(
        from occurrence: SetlistOccurrence,
        score: Double,
        confidenceLabel: ConfidenceLabel,
        reason: String
    ) -> SongCandidate {
        SongCandidate(
            song: SongIdentity(
                id: "setlist:\(occurrence.id)",
                title: occurrence.title,
                artist: occurrence.artist
            ),
            setlistOccurrenceID: occurrence.id,
            evidenceScore: score,
            confidenceLabel: confidenceLabel,
            reasons: [reason]
        )
    }
}

private struct SetlistContext {
    let occurrences: [SetlistOccurrence]
    private let occurrenceByID: [String: SetlistOccurrence]
    private let uniqueOccurrenceByTitleArtistKey: [String: SetlistOccurrence]
    private let uniqueOccurrenceByTitleKey: [String: SetlistOccurrence]
    private let uniqueOccurrenceByComparableTitleKey: [String: SetlistOccurrence]

    private struct SimilarityMatch {
        let occurrence: SetlistOccurrence
        let score: Double
        let titleScore: Double
        let reason: String
        let comparableTitleKey: String
    }

    init(setlist: ConcertSetlist?) {
        occurrences = (setlist?.occurrences ?? []).sorted { $0.overallIndex < $1.overallIndex }
        occurrenceByID = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0) })
        uniqueOccurrenceByTitleArtistKey = Dictionary(
            grouping: occurrences,
            by: { Self.titleArtistKey(title: $0.title, artist: $0.artist) }
        )
        .compactMapValues { $0.count == 1 ? $0[0] : nil }
        uniqueOccurrenceByTitleKey = Dictionary(
            grouping: occurrences,
            by: { TextNormalizer.normalizeSongTitle($0.title) }
        )
        .compactMapValues { $0.count == 1 ? $0[0] : nil }
        uniqueOccurrenceByComparableTitleKey = Dictionary(
            grouping: occurrences,
            by: { Self.comparableTitleKey($0.title) }
        )
        .compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    func resolveOccurrence(for candidate: SongCandidate) -> SetlistOccurrence? {
        if let occurrenceID = candidate.setlistOccurrenceID,
           let occurrence = occurrenceByID[occurrenceID] {
            return occurrence
        }

        let titleArtistKey = Self.titleArtistKey(title: candidate.song.title, artist: candidate.song.artist)
        if let occurrence = uniqueOccurrenceByTitleArtistKey[titleArtistKey] {
            return occurrence
        }

        let titleKey = TextNormalizer.normalizeSongTitle(candidate.song.title)
        if let occurrence = uniqueOccurrenceByTitleKey[titleKey] {
            return occurrence
        }

        let comparableTitleKey = Self.comparableTitleKey(candidate.song.title)
        if let occurrence = uniqueOccurrenceByComparableTitleKey[comparableTitleKey] {
            CoreLog.mediaClassification.info("Setlist title similarity accepted candidateTitle=\(candidate.song.title, privacy: .public) candidateArtist=\(candidate.song.artist, privacy: .public) occurrenceTitle=\(occurrence.title, privacy: .public) occurrenceArtist=\(occurrence.artist, privacy: .public) overallIndex=\(occurrence.overallIndex, privacy: .public) score=1.000000 titleScore=1.000000 margin=1.000000 reason=comparable-title-exact")
            return occurrence
        }

        return resolveBySimilarity(for: candidate)
    }

    var overallIndexBounds: ClosedRange<Int>? {
        guard let lower = occurrences.map(\.overallIndex).min(),
              let upper = occurrences.map(\.overallIndex).max() else {
            return nil
        }
        return lower...upper
    }

    func candidates(in range: ClosedRange<Int>, reason: String) -> [SongCandidate] {
        occurrences
            .filter { range.contains($0.overallIndex) }
            .map {
                SongCandidate(
                    song: SongIdentity(id: "setlist:\($0.id)", title: $0.title, artist: $0.artist),
                    setlistOccurrenceID: $0.id,
                    evidenceScore: 1,
                    confidenceLabel: .possible,
                    reasons: [reason]
                )
            }
    }

    private static func titleArtistKey(title: String, artist: String) -> String {
        "\(TextNormalizer.normalizeText(artist))|\(TextNormalizer.normalizeSongTitle(title))"
    }

    private func resolveBySimilarity(for candidate: SongCandidate) -> SetlistOccurrence? {
        let matches = occurrences
            .map { occurrence -> SimilarityMatch in
                let titleSimilarity = Self.titleSimilarity(candidateTitle: candidate.song.title, occurrenceTitle: occurrence.title)
                let artistCompatible = Self.artistsAreCompatible(candidate.song.artist, occurrence.artist)
                let adjustedScore = min(1, titleSimilarity.score + (artistCompatible ? 0.03 : 0))
                return SimilarityMatch(
                    occurrence: occurrence,
                    score: adjustedScore,
                    titleScore: titleSimilarity.score,
                    reason: titleSimilarity.reason,
                    comparableTitleKey: Self.comparableTitleKey(occurrence.title)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.occurrence.overallIndex < rhs.occurrence.overallIndex
                }
                return lhs.score > rhs.score
            }

        guard let best = matches.first, best.score >= 0.82 else {
            if let best = matches.first, best.score >= 0.65 {
                CoreLog.mediaClassification.info("Setlist title similarity rejected candidateTitle=\(candidate.song.title, privacy: .public) candidateArtist=\(candidate.song.artist, privacy: .public) bestOccurrenceTitle=\(best.occurrence.title, privacy: .public) bestOccurrenceArtist=\(best.occurrence.artist, privacy: .public) bestOverallIndex=\(best.occurrence.overallIndex, privacy: .public) score=\(best.score, privacy: .public) titleScore=\(best.titleScore, privacy: .public) reason=below-threshold bestReason=\(best.reason, privacy: .public)")
            }
            return nil
        }

        let secondScore = matches.dropFirst().first?.score ?? 0
        let margin = best.score - secondScore
        let duplicateBestTitleCount = occurrences.filter { Self.comparableTitleKey($0.title) == best.comparableTitleKey }.count
        if duplicateBestTitleCount > 1 {
            CoreLog.mediaClassification.info("Setlist title similarity ambiguous candidateTitle=\(candidate.song.title, privacy: .public) candidateArtist=\(candidate.song.artist, privacy: .public) bestOccurrenceTitle=\(best.occurrence.title, privacy: .public) duplicateTitleCount=\(duplicateBestTitleCount, privacy: .public) score=\(best.score, privacy: .public) titleScore=\(best.titleScore, privacy: .public) reason=duplicate-setlist-title")
            return nil
        }

        guard margin >= 0.08 || best.score >= 0.92 else {
            CoreLog.mediaClassification.info("Setlist title similarity rejected candidateTitle=\(candidate.song.title, privacy: .public) candidateArtist=\(candidate.song.artist, privacy: .public) bestOccurrenceTitle=\(best.occurrence.title, privacy: .public) bestOccurrenceArtist=\(best.occurrence.artist, privacy: .public) bestOverallIndex=\(best.occurrence.overallIndex, privacy: .public) score=\(best.score, privacy: .public) titleScore=\(best.titleScore, privacy: .public) margin=\(margin, privacy: .public) reason=low-margin bestReason=\(best.reason, privacy: .public)")
            return nil
        }

        CoreLog.mediaClassification.info("Setlist title similarity accepted candidateTitle=\(candidate.song.title, privacy: .public) candidateArtist=\(candidate.song.artist, privacy: .public) occurrenceTitle=\(best.occurrence.title, privacy: .public) occurrenceArtist=\(best.occurrence.artist, privacy: .public) overallIndex=\(best.occurrence.overallIndex, privacy: .public) score=\(best.score, privacy: .public) titleScore=\(best.titleScore, privacy: .public) margin=\(margin, privacy: .public) reason=\(best.reason, privacy: .public)")
        return best.occurrence
    }

    private static func titleSimilarity(candidateTitle: String, occurrenceTitle: String) -> (score: Double, reason: String) {
        let candidateNormalized = TextNormalizer.normalizeSongTitle(candidateTitle)
        let occurrenceNormalized = TextNormalizer.normalizeSongTitle(occurrenceTitle)
        if candidateNormalized == occurrenceNormalized {
            return (1, "normalized-title-exact")
        }

        let candidateTokens = comparableTitleTokens(candidateTitle)
        let occurrenceTokens = comparableTitleTokens(occurrenceTitle)
        guard !candidateTokens.isEmpty, !occurrenceTokens.isEmpty else {
            return (0, "empty-comparable-title")
        }

        if candidateTokens == occurrenceTokens {
            return (0.98, "comparable-token-exact")
        }

        let candidateTokenSet = Set(candidateTokens)
        let occurrenceTokenSet = Set(occurrenceTokens)
        if occurrenceTokenSet.isSubset(of: candidateTokenSet) {
            return (0.94, "setlist-title-contained-in-recognized-title")
        }

        if candidateTokenSet.isSubset(of: occurrenceTokenSet) {
            return (0.88, "recognized-title-contained-in-setlist-title")
        }

        let tokenScore = Similarity.tokenFuzzyScore(candidateTokens, occurrenceTokens)
        let editScore = Similarity.normalizedEditSimilarity(candidateTokens.joined(separator: " "), occurrenceTokens.joined(separator: " "))
        return ((tokenScore * 0.70) + (editScore * 0.30), "token-edit-similarity")
    }

    private static func comparableTitleKey(_ title: String) -> String {
        comparableTitleTokens(title).joined(separator: " ")
    }

    private static func comparableTitleTokens(_ title: String) -> [String] {
        let descriptorTokens: Set<String> = [
            "feat", "featuring", "ft", "with",
            "remix", "mix", "live", "version", "edit", "cover",
            "remastered", "remaster", "explicit", "album", "radio", "deluxe"
        ]
        let tokens = TextNormalizer.tokens(title).filter { !descriptorTokens.contains($0) }
        return tokens.isEmpty ? TextNormalizer.tokens(title) : tokens
    }

    private static func artistsAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let left = TextNormalizer.normalizeText(lhs)
        let right = TextNormalizer.normalizeText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }
}

private struct BoundedSongRange: Hashable {
    let lowerOverallIndex: Int
    let upperOverallIndex: Int
    let options: [SongCandidate]
    let suggestedAnchor: AbsoluteSongAnchor?
    let suggestedCandidate: SongCandidate?
    let status: SegmentStatus
    let score: Double
    let reason: String
}

private struct AbsoluteSongAnchor: Hashable {
    let videoID: UUID
    let segmentID: UUID
    let start: Date
    let end: Date
    let candidate: SongCandidate
    let occurrence: SetlistOccurrence?
    let status: SegmentStatus

    func contains(_ date: Date, padding: TimeInterval) -> Bool {
        date >= start.addingTimeInterval(-padding) && date <= end.addingTimeInterval(padding)
    }
}
