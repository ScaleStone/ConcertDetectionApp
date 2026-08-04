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
    /// 0-1 proxy for clean audio (Shazam matched-duration ratio).
    let audioClarity: Double?
    let isGuestFeature: Bool
    let featuredArtist: String?
    /// Segment bounds in the video file's timeline (clip-range defaults).
    let segmentStartSeconds: Double?
    let segmentEndSeconds: Double?
    let videoDurationSeconds: Double?
    let frames: [String]
}

struct SuggestionsRequestDTO: Encodable {
    let concertTitle: String
    let venue: String?
    let eventDate: String?
    let headlinerArtist: String?
    let candidates: [SuggestionCandidateDTO]
    /// Testing: ask the backend for a scored evaluation of every candidate.
    let debug: Bool
}

/// Suggestion categories with per-category caps enforced by the backend.
enum SuggestionCategory: String, Decodable, CaseIterable {
    case bestQuality
    case uniqueMoment
    case artistFeature
    case photoSlideshow

    var displayName: String {
        switch self {
        case .bestQuality: return "Best Quality"
        case .uniqueMoment: return "Unique Moments"
        case .artistFeature: return "Artist Feature"
        case .photoSlideshow: return "Photo Slideshow"
        }
    }

    var systemImage: String {
        switch self {
        case .bestQuality: return "sparkles.tv"
        case .uniqueMoment: return "flame"
        case .artistFeature: return "person.2.fill"
        case .photoSlideshow: return "photo.stack"
        }
    }

    /// Display order in the Post Ideas section.
    static let displayOrder: [SuggestionCategory] = [.artistFeature, .uniqueMoment, .bestQuality, .photoSlideshow]
}

struct PostSuggestionDTO: Codable, Identifiable, Hashable {
    let candidateId: String
    let category: String
    let rank: Int
    let reason: String
    let caption: String
    let hashtags: [String]
    let clipStartSeconds: Double?
    let clipEndSeconds: Double?

    var id: String { candidateId }

    var suggestionCategory: SuggestionCategory? {
        SuggestionCategory(rawValue: category)
    }

    var clipRange: ClosedRange<Double>? {
        guard let clipStartSeconds, let clipEndSeconds, clipEndSeconds > clipStartSeconds else { return nil }
        return clipStartSeconds...clipEndSeconds
    }
}

struct CandidateEvaluationDTO: Codable, Identifiable, Hashable {
    let candidateId: String
    let score: Int
    let reasoning: String
    let category: String?

    var id: String { candidateId }
}

struct SuggestionsResponseDTO: Codable {
    let suggestions: [PostSuggestionDTO]
    let promptVersion: String
    let trendBriefVersion: String
    /// Present only when the request set debug=true.
    let evaluations: [CandidateEvaluationDTO]?
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
    private let diskCache = SuggestionDiskCache()

    init(client: BackendAPIClient) {
        self.client = client
    }

    /// Cache key covers the concert's content (updatedAt changes whenever
    /// media/setlist change).
    private func cacheKey(for concert: ConcertRecord, includeScores: Bool) -> String {
        "\(concert.id.uuidString)-\(concert.updatedAt.timeIntervalSince1970)-scores:\(includeScores)"
    }

    /// Serves memory, then disk, then network. Persisting to disk means app
    /// relaunches never re-spend an LLM request (and provider rate-limit
    /// budget) for an unchanged concert; `forceRefresh` (the Refresh menu
    /// action) is the explicit way to re-fetch and pick up new trend briefs.
    func suggestions(for concert: ConcertRecord, includeScores: Bool = false, forceRefresh: Bool = false) async throws -> Result {
        let key = cacheKey(for: concert, includeScores: includeScores)
        if !forceRefresh {
            if let cached = cache[key] {
                AppLog.postIdeas.info("Post ideas served from memory cache concert=\(concert.id.uuidString, privacy: .public)")
                return cached
            }
            if let persisted = diskCache.load(key: key) {
                // Rebuild candidates locally (fast, on-device) so thumbnails
                // and share targets rejoin the persisted response by ID.
                let rebuilt = await SuggestionCandidateBuilder.build(for: concert)
                let result = Result(
                    response: persisted,
                    candidatesByID: Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.dto.id, $0) })
                )
                cache[key] = result
                AppLog.postIdeas.info("Post ideas served from disk cache concert=\(concert.id.uuidString, privacy: .public)")
                return result
            }
        }

        let built = await SuggestionCandidateBuilder.build(for: concert)
        guard !built.isEmpty else {
            throw ConcertSongFinderError.unknown("This concert has no media to suggest from yet.")
        }

        let request = SuggestionsRequestDTO(
            concertTitle: concert.displayTitle,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate.map { Self.dateOnlyFormatter.string(from: $0) },
            headlinerArtist: concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName,
            candidates: built.map(\.dto),
            debug: includeScores
        )

        AppLog.postIdeas.info("Requesting post ideas concert=\(concert.id.uuidString, privacy: .public) candidates=\(built.count, privacy: .public) scores=\(includeScores, privacy: .public)")
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
        diskCache.save(response, key: key)
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

// MARK: - Disk cache

/// Small JSON-file cache of suggestion responses, keyed by concert content.
/// Responses only (no frames, no images) so the file stays tiny. Entries
/// expire after 24h so refreshed trend briefs propagate within a day, and
/// the store is pruned to the newest 20 entries.
private struct SuggestionDiskCache {
    private struct Entry: Codable {
        let savedAt: Date
        let response: SuggestionsResponseDTO
    }

    private let maxEntries = 20
    private let timeToLive: TimeInterval = 24 * 60 * 60

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConcertSongFinder", isDirectory: true)
            .appendingPathComponent("post-ideas-cache.json")
    }

    func load(key: String) -> SuggestionsResponseDTO? {
        guard let entry = loadAll()[key], Date().timeIntervalSince(entry.savedAt) < timeToLive else {
            return nil
        }
        return entry.response
    }

    func save(_ response: SuggestionsResponseDTO, key: String) {
        var entries = loadAll()
        entries[key] = Entry(savedAt: Date(), response: response)
        // Prune expired entries and cap total size, oldest first.
        entries = entries.filter { Date().timeIntervalSince($0.value.savedAt) < timeToLive }
        if entries.count > maxEntries {
            let sortedKeys = entries.sorted { $0.value.savedAt < $1.value.savedAt }.map(\.key)
            for staleKey in sortedKeys.prefix(entries.count - maxEntries) {
                entries.removeValue(forKey: staleKey)
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.postIdeas.error("Post ideas disk cache write failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAll() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }
}
