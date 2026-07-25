import ConcertSongFinderCore
import Foundation

// MARK: - DTOs (must mirror backend/app/models/suggestions.py exactly)

struct SuggestionCandidateDTO: Encodable {
    let id: String
    let kind: String
    let songTitle: String?
    let artist: String?
    let isEncore: Bool
    let isRareSong: Bool
    let setlistPosition: Int?
    let durationSeconds: Double?
    let contextNotes: String?
    let frames: [String]
}

struct SuggestionsRequestDTO: Encodable {
    let concertTitle: String
    let venue: String?
    let eventDate: String?
    let candidates: [SuggestionCandidateDTO]
}

struct PostSuggestionDTO: Decodable, Identifiable, Hashable {
    let candidateId: String
    let rank: Int
    let reason: String
    let caption: String
    let hashtags: [String]

    var id: String { candidateId }
}

struct SuggestionsResponseDTO: Decodable {
    let suggestions: [PostSuggestionDTO]
    let promptVersion: String
    let trendBriefVersion: String
}

// MARK: - Service

/// Fetches TikTok post suggestions for a concert from the backend, with an
/// in-memory per-concert cache so re-opening a concert never re-sends frames
/// or re-spends LLM budget within a session.
@MainActor
final class SuggestionService: ObservableObject {
    struct Result {
        let response: SuggestionsResponseDTO
        /// candidateId → the on-device media item, for thumbnails + sharing.
        let candidatesByID: [String: SuggestionCandidateBuilder.BuiltCandidate]
    }

    private let client: BackendAPIClient
    private var cache: [String: Result] = [:]

    init(client: BackendAPIClient) {
        self.client = client
    }

    /// Cache key covers the concert's content (updatedAt changes whenever
    /// media/setlist change). The trend-brief version is server-side, so the
    /// cache is session-scoped only; a fresh launch picks up new briefs.
    private func cacheKey(for concert: ConcertRecord) -> String {
        "\(concert.id.uuidString)-\(concert.updatedAt.timeIntervalSince1970)"
    }

    func suggestions(for concert: ConcertRecord) async throws -> Result {
        let key = cacheKey(for: concert)
        if let cached = cache[key] {
            AppLog.postIdeas.info("Post ideas served from cache concert=\(concert.id.uuidString, privacy: .public)")
            return cached
        }

        let built = await SuggestionCandidateBuilder.build(for: concert)
        guard !built.isEmpty else {
            throw ConcertSongFinderError.unknown("This concert has no media to suggest from yet.")
        }

        let request = SuggestionsRequestDTO(
            concertTitle: concert.displayTitle,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate.map { Self.dateOnlyFormatter.string(from: $0) },
            candidates: built.map(\.dto)
        )

        AppLog.postIdeas.info("Requesting post ideas concert=\(concert.id.uuidString, privacy: .public) candidates=\(built.count, privacy: .public)")
        // Generous timeout: Render free-tier cold start plus LLM latency.
        let response = try await client.post(
            "api/suggestions",
            body: request,
            responseType: SuggestionsResponseDTO.self,
            timeout: 90
        )
        AppLog.postIdeas.info("Post ideas received concert=\(concert.id.uuidString, privacy: .public) count=\(response.suggestions.count, privacy: .public) prompt=\(response.promptVersion, privacy: .public) brief=\(response.trendBriefVersion, privacy: .public)")

        let result = Result(
            response: response,
            candidatesByID: Dictionary(uniqueKeysWithValues: built.map { ($0.dto.id, $0) })
        )
        cache[key] = result
        return result
    }

    /// Acceptance telemetry seed (task 3.4): outcomes are recorded in the
    /// on-device structured log together with the prompt/brief versions, so
    /// taste can be compared across versions without any tracking SDK.
    func logOutcome(_ outcome: String, suggestion: PostSuggestionDTO, response: SuggestionsResponseDTO, concert: ConcertRecord) {
        AppLog.postIdeas.info("Post idea \(outcome, privacy: .public) concert=\(concert.id.uuidString, privacy: .public) candidate=\(suggestion.candidateId, privacy: .public) rank=\(suggestion.rank, privacy: .public) prompt=\(response.promptVersion, privacy: .public) brief=\(response.trendBriefVersion, privacy: .public)")
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
