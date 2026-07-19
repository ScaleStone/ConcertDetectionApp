import Foundation

/// Groups concert media by song for the library detail view: matching media
/// to setlist occurrences, and grouping reliably recognized songs that are
/// not on the setlist (or when no setlist exists at all) so identified media
/// is always browsable under a song label.
public enum ConcertMediaGrouping {
    /// Statuses that count as a reliable song identification.
    public static let reliableStatuses: Set<SegmentStatus> = [.identified, .likely, .userConfirmed]

    /// Whether a recognized candidate corresponds to a setlist occurrence.
    /// Falls back to qualifier-stripped title comparison so Shazam titles
    /// like "Song (feat. X)" match setlist entries titled "Song".
    public static func candidateMatches(_ candidate: SongCandidate, occurrence: SetlistOccurrence) -> Bool {
        if candidate.setlistOccurrenceID == occurrence.id { return true }
        let candidateKey = TextNormalizer.normalizedSongKey(title: candidate.song.title, artist: candidate.song.artist)
        let occurrenceKey = TextNormalizer.normalizedSongKey(title: occurrence.title, artist: occurrence.artist)
        if candidateKey == occurrenceKey { return true }
        let candidateTitle = TextNormalizer.comparableSongTitle(candidate.song.title)
        let occurrenceTitle = TextNormalizer.comparableSongTitle(occurrence.title)
        return !candidateTitle.isEmpty && candidateTitle == occurrenceTitle
    }

    public struct VideoSegmentPair: Identifiable, Hashable {
        public var id: UUID { segment.id }
        public let video: ConcertVideo
        public let segment: SongSegment

        public init(video: ConcertVideo, segment: SongSegment) {
            self.video = video
            self.segment = segment
        }
    }

    /// A distinct recognized song and the media identified as it.
    public struct RecognizedSongGroup: Identifiable, Hashable {
        /// Normalized artist|title key.
        public let id: String
        /// Representative identity (first candidate seen for this song).
        public let song: SongIdentity
        public let videoSegments: [VideoSegmentPair]
        public let photos: [ConcertPhoto]
        /// Earliest capture timestamp among the group's media.
        public let earliestDate: Date?
    }

    /// Builds groups for reliably recognized songs that do NOT match any
    /// setlist occurrence. With no setlist, every reliably recognized song
    /// gets a group, so recognition results remain browsable even when
    /// setlist lookup failed.
    public static func recognizedSongGroups(
        videos: [ConcertVideo],
        photos: [ConcertPhoto],
        setlist: ConcertSetlist?
    ) -> [RecognizedSongGroup] {
        let occurrences = setlist?.occurrences ?? []

        func matchesSetlist(_ candidate: SongCandidate) -> Bool {
            occurrences.contains { candidateMatches(candidate, occurrence: $0) }
        }

        func groupKey(for song: SongIdentity) -> String {
            "\(TextNormalizer.normalizeText(song.artist))|\(TextNormalizer.comparableSongTitle(song.title))"
        }

        struct Builder {
            var song: SongIdentity
            var videoSegments: [VideoSegmentPair] = []
            var photos: [ConcertPhoto] = []
            var earliestDate: Date?
        }

        var builders: [String: Builder] = [:]
        var order: [String] = []

        func builder(for song: SongIdentity, mediaDate: Date?) -> String {
            let key = groupKey(for: song)
            if builders[key] == nil {
                builders[key] = Builder(song: song)
                order.append(key)
            }
            if let mediaDate {
                if let existing = builders[key]?.earliestDate {
                    builders[key]?.earliestDate = min(existing, mediaDate)
                } else {
                    builders[key]?.earliestDate = mediaDate
                }
            }
            return key
        }

        for video in videos {
            for segment in video.segments {
                guard reliableStatuses.contains(segment.status),
                      let candidate = segment.primaryCandidate,
                      !matchesSetlist(candidate) else {
                    continue
                }
                let key = builder(for: candidate.song, mediaDate: video.createdAt)
                builders[key]?.videoSegments.append(VideoSegmentPair(video: video, segment: segment))
            }
        }

        for photo in photos {
            guard let candidate = photo.primaryCandidate,
                  !matchesSetlist(candidate) else {
                continue
            }
            let key = builder(for: candidate.song, mediaDate: photo.createdAt)
            builders[key]?.photos.append(photo)
        }

        return order
            .compactMap { key -> RecognizedSongGroup? in
                guard let built = builders[key] else { return nil }
                return RecognizedSongGroup(
                    id: key,
                    song: built.song,
                    videoSegments: built.videoSegments,
                    photos: built.photos,
                    earliestDate: built.earliestDate
                )
            }
            .sorted {
                switch ($0.earliestDate, $1.earliestDate) {
                case let (.some(left), .some(right)) where left != right:
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return $0.song.title < $1.song.title
                }
            }
    }
}
