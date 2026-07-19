import ConcertSongFinderCore
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let videoImportService: any VideoImportService
    let audioExtractionService: any AudioExtractionService
    let musicRecognitionService: any MusicRecognitionService
    let setlistService: any SetlistService
    let speechTranscriptionService: any SpeechTranscriptionService
    let lyricsService: any LyricsService
    let timelineBuilder: any TimelineBuildingService
    let alignmentService: DefaultSetlistAlignmentService
    let lyricMatchingService: any LyricMatchingService
    let historyStore: any AnalysisHistoryStoring
    let concertLibraryStore: any ConcertLibraryStoring

    init(
        videoImportService: any VideoImportService,
        audioExtractionService: any AudioExtractionService,
        musicRecognitionService: any MusicRecognitionService,
        setlistService: any SetlistService,
        speechTranscriptionService: any SpeechTranscriptionService,
        lyricsService: any LyricsService,
        timelineBuilder: any TimelineBuildingService,
        alignmentService: DefaultSetlistAlignmentService,
        lyricMatchingService: any LyricMatchingService,
        historyStore: any AnalysisHistoryStoring,
        concertLibraryStore: any ConcertLibraryStoring
    ) {
        self.videoImportService = videoImportService
        self.audioExtractionService = audioExtractionService
        self.musicRecognitionService = musicRecognitionService
        self.setlistService = setlistService
        self.speechTranscriptionService = speechTranscriptionService
        self.lyricsService = lyricsService
        self.timelineBuilder = timelineBuilder
        self.alignmentService = alignmentService
        self.lyricMatchingService = lyricMatchingService
        self.historyStore = historyStore
        self.concertLibraryStore = concertLibraryStore
    }

    static func live() -> AppEnvironment {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConcertSongFinder", isDirectory: true)
        let backend = BackendAPIClient(baseURL: backendBaseURL, apiKey: backendAPIKey)
        return AppEnvironment(
            videoImportService: LiveVideoImportService(workingDirectory: supportDirectory.appendingPathComponent("Videos", isDirectory: true)),
            audioExtractionService: LiveAudioExtractionService(temporaryDirectory: FileManager.default.temporaryDirectory),
            musicRecognitionService: ShazamMusicRecognitionService(),
            setlistService: BackendSetlistService(client: backend),
            speechTranscriptionService: AppleSpeechTranscriptionService(),
            lyricsService: BackendLyricsService(client: backend),
            timelineBuilder: DefaultTimelineBuilder(),
            alignmentService: DefaultSetlistAlignmentService(),
            lyricMatchingService: DefaultLyricMatchingService(),
            historyStore: JSONAnalysisHistoryStore(fileURL: supportDirectory.appendingPathComponent("analysis-history.json")),
            concertLibraryStore: JSONConcertLibraryStore(fileURL: supportDirectory.appendingPathComponent("concert-library.json"))
        )
    }

    private static var backendBaseURL: URL? {
        if let configuredValue = Bundle.main.object(forInfoDictionaryKey: "CSFBackendBaseURL") as? String {
            let trimmedValue = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty, let configuredURL = URL(string: trimmedValue) {
                return configuredURL
            }
        }

        #if targetEnvironment(simulator)
        // The simulator shares the Mac's network stack, so localhost works.
        return URL(string: "http://127.0.0.1:8000")
        #else
        // On a physical device the backend URL must be configured explicitly;
        // requests will surface a clear "backend not configured" error.
        return nil
        #endif
    }

    private static var backendAPIKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CSFBackendAPIKey") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
