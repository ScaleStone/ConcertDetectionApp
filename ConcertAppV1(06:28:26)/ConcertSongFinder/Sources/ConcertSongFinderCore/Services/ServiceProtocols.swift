import Foundation

public protocol AudioExtractionService {
    func prepareAudio(for video: ConcertVideo) async throws -> PreparedAudio
}

public protocol MusicRecognitionService {
    func recognize(
        audio: PreparedAudio,
        configuration: RecognitionConfiguration
    ) async throws -> [RawRecognitionMatch]
}

public protocol SetlistService {
    func searchConcerts(
        artist: String?,
        date: Date?,
        venue: String?,
        location: VideoLocation?,
        cityName: String?,
        stateCode: String?,
        countryCode: String?
    ) async throws -> [ConcertCandidate]

    func fetchSetlist(id: String) async throws -> ConcertSetlist
}

public protocol SpeechTranscriptionService {
    func transcribe(
        audioURL: URL,
        timeRange: Range<TimeInterval>,
        locale: Locale?
    ) async throws -> [TranscriptAlternative]
}

public protocol LyricsService {
    func lyrics(for songs: [SongIdentity]) async throws -> [SongLyrics]
}

public protocol TimelineBuildingService {
    func buildTimeline(
        duration: TimeInterval,
        rawMatches: [RawRecognitionMatch],
        configuration: RecognitionConfiguration
    ) -> [SongSegment]
}

public extension TimelineBuildingService {
    func buildTimeline(duration: TimeInterval, rawMatches: [RawRecognitionMatch]) -> [SongSegment] {
        buildTimeline(duration: duration, rawMatches: rawMatches, configuration: .default)
    }
}

public protocol SetlistAlignmentService {
    func align(
        observations: [SongObservation],
        to occurrences: [SetlistOccurrence]
    ) -> SetlistAlignment
}

public protocol LyricMatchingService {
    func rankCandidates(
        transcripts: [TranscriptAlternative],
        lyrics: [SongLyrics],
        occurrences: [SetlistOccurrence],
        context: RecognitionContext
    ) -> [SongCandidate]
}

public enum ConcertSongFinderError: Error, Codable, Hashable, LocalizedError {
    case noAudioTrack
    case videoImportCanceled
    case iCloudDownloadFailed
    case unsupportedMedia
    case corruptedVideo
    case missingMetadata
    case photoPermissionDenied
    case speechPermissionDenied
    case speechRecognizerUnavailable
    case shazamNoMatch
    case noSetlistFound
    case severalSetlistsFound
    case setlistMissingSongs
    case lyricsUnavailable
    case lyricProviderFailure
    case networkUnavailable
    case backendUnavailable
    case rateLimited
    case analysisCanceled
    case appBackgrounded
    case insufficientStorage
    case unreleasedSong
    case unrecognizableAudio
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This video does not contain an audio track."
        case .videoImportCanceled: "Video import was canceled."
        case .iCloudDownloadFailed: "The video could not be downloaded from iCloud."
        case .unsupportedMedia: "This media format is not supported."
        case .corruptedVideo: "The video appears to be corrupted."
        case .missingMetadata: "Recording metadata is missing or unreliable."
        case .photoPermissionDenied: "Photo library access is required to import concert videos."
        case .speechPermissionDenied: "Speech recognition permission is required to transcribe unclear audio."
        case .speechRecognizerUnavailable: "Speech recognition is currently unavailable."
        case .shazamNoMatch: "Shazam did not find a reliable match."
        case .noSetlistFound: "No matching setlist was found."
        case .severalSetlistsFound: "Several possible setlists were found. Please choose one."
        case .setlistMissingSongs: "The selected setlist appears to be incomplete."
        case .lyricsUnavailable: "Lyrics are unavailable for one or more candidate songs."
        case .lyricProviderFailure: "The lyric provider could not complete the request."
        case .networkUnavailable: "The network is unavailable."
        case .backendUnavailable: "The ConcertSongFinder backend is unavailable."
        case .rateLimited: "A provider rate limit was reached. Please try again later."
        case .analysisCanceled: "Analysis was canceled."
        case .appBackgrounded: "Analysis paused because the app moved to the background."
        case .insufficientStorage: "There is not enough storage to process this video."
        case .unreleasedSong: "This may be an unreleased or unavailable song."
        case .unrecognizableAudio: "The audio does not contain enough recognizable information."
        case .unknown(let message): message
        }
    }
}
