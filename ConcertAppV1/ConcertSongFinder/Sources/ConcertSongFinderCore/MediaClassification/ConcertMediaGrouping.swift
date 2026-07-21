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

    /// A single entry in a concert's media library grid: one media item
    /// (or one video+song pairing) labeled with its song.
    public struct MediaLibraryItem: Identifiable, Hashable {
        public enum Media: Hashable {
            case video(ConcertVideo, segment: SongSegment?)
            case photo(ConcertPhoto)
        }

        public let id: String
        public let media: Media
        /// nil when the media has no reliable song identification.
        public let songTitle: String?
        public let songArtist: String?
        public let capturedAt: Date?

        public var displayLabel: String {
            songTitle ?? "Unknown"
        }
    }

    /// Flattens a concert's media into library items labeled by song.
    ///
    /// Videos produce one item per distinct reliably-identified song (a
    /// multi-song video appears once per song, so searching either song
    /// finds it); videos with no reliable identification appear once as
    /// "Unknown". Song names prefer the setlist's clean title when the
    /// recognized candidate matches an occurrence. Items sort by capture
    /// time, undated media last.
    public static func libraryItems(
        videos: [ConcertVideo],
        photos: [ConcertPhoto],
        setlist: ConcertSetlist?
    ) -> [MediaLibraryItem] {
        let occurrences = setlist?.occurrences ?? []

        func cleanSong(for candidate: SongCandidate) -> (title: String, artist: String) {
            if let occurrence = occurrences.first(where: { candidateMatches(candidate, occurrence: $0) }) {
                return (occurrence.title, occurrence.artist)
            }
            return (candidate.song.title, candidate.song.artist)
        }

        func songKey(title: String, artist: String) -> String {
            "\(TextNormalizer.normalizeText(artist))|\(TextNormalizer.comparableSongTitle(title))"
        }

        var items: [MediaLibraryItem] = []

        for video in videos {
            var seenSongKeys = Set<String>()
            var videoItems: [MediaLibraryItem] = []
            for segment in video.segments {
                guard reliableStatuses.contains(segment.status),
                      let candidate = segment.primaryCandidate else { continue }
                let song = cleanSong(for: candidate)
                guard seenSongKeys.insert(songKey(title: song.title, artist: song.artist)).inserted else { continue }
                videoItems.append(
                    MediaLibraryItem(
                        id: "video-\(video.id.uuidString)-\(segment.id.uuidString)",
                        media: .video(video, segment: segment),
                        songTitle: song.title,
                        songArtist: song.artist,
                        capturedAt: video.createdAt
                    )
                )
            }
            if videoItems.isEmpty {
                items.append(
                    MediaLibraryItem(
                        id: "video-\(video.id.uuidString)",
                        media: .video(video, segment: nil),
                        songTitle: nil,
                        songArtist: nil,
                        capturedAt: video.createdAt
                    )
                )
            } else {
                items.append(contentsOf: videoItems)
            }
        }

        for photo in photos {
            if let candidate = photo.primaryCandidate {
                let song = cleanSong(for: candidate)
                items.append(
                    MediaLibraryItem(
                        id: "photo-\(photo.id.uuidString)",
                        media: .photo(photo),
                        songTitle: song.title,
                        songArtist: song.artist,
                        capturedAt: photo.createdAt
                    )
                )
            } else {
                items.append(
                    MediaLibraryItem(
                        id: "photo-\(photo.id.uuidString)",
                        media: .photo(photo),
                        songTitle: nil,
                        songArtist: nil,
                        capturedAt: photo.createdAt
                    )
                )
            }
        }

        return items.sorted {
            switch ($0.capturedAt, $1.capturedAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.displayLabel < $1.displayLabel
            }
        }
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
