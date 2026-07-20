import Foundation

public final class MockSetlistService: SetlistService {
    public var candidates: [ConcertCandidate]
    public var setlist: ConcertSetlist?

    public init(candidates: [ConcertCandidate] = [], setlist: ConcertSetlist? = nil) {
        self.candidates = candidates
        self.setlist = setlist
    }

    public func searchConcerts(
        artist: String?,
        date: Date?,
        venue: String?,
        location: VideoLocation?,
        cityName: String?,
        stateCode: String?,
        countryCode: String?
    ) async throws -> [ConcertCandidate] {
        if candidates.isEmpty, let setlist {
            return [
                ConcertCandidate(
                    id: setlist.id,
                    artistName: setlist.artistName,
                    venueName: setlist.venueName,
                    city: nil,
                    eventDate: setlist.eventDate,
                    confidenceScore: 0.6,
                    attributionURL: setlist.attributionURL
                )
            ]
        }
        return candidates
    }

    public func fetchSetlist(id: String) async throws -> ConcertSetlist {
        guard let setlist else { throw ConcertSongFinderError.noSetlistFound }
        return setlist
    }
}

public final class MockLyricsService: LyricsService {
    public var responses: [SongLyrics]

    public init(responses: [SongLyrics] = []) {
        self.responses = responses
    }

    public func lyrics(for songs: [SongIdentity]) async throws -> [SongLyrics] {
        let requestedKeys = Set(songs.map { TextNormalizer.normalizedSongKey(title: $0.title, artist: $0.artist, isrc: $0.isrc) })
        return responses.filter {
            requestedKeys.contains(TextNormalizer.normalizedSongKey(title: $0.song.title, artist: $0.song.artist, isrc: $0.song.isrc))
        }
    }
}

public final class MockMusicRecognitionService: MusicRecognitionService {
    public var matchesByAudioURL: [URL: [RawRecognitionMatch]]
    public var defaultMatches: [RawRecognitionMatch]

    public init(matchesByAudioURL: [URL: [RawRecognitionMatch]] = [:], defaultMatches: [RawRecognitionMatch] = []) {
        self.matchesByAudioURL = matchesByAudioURL
        self.defaultMatches = defaultMatches
    }

    public func recognize(
        audio: PreparedAudio,
        configuration: RecognitionConfiguration
    ) async throws -> [RawRecognitionMatch] {
        matchesByAudioURL[audio.audioURL] ?? defaultMatches
    }
}

public final class MockSpeechTranscriptionService: SpeechTranscriptionService {
    public var alternatives: [TranscriptAlternative]

    public init(alternatives: [TranscriptAlternative] = []) {
        self.alternatives = alternatives
    }

    public func transcribe(
        audioURL: URL,
        timeRange: Range<TimeInterval>,
        locale: Locale?
    ) async throws -> [TranscriptAlternative] {
        alternatives
    }
}
