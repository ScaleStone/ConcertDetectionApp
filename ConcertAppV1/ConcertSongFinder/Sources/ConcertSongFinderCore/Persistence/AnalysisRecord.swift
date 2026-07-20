import Foundation

public struct AnalysisRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var videos: [ConcertVideo]
    public var photos: [ConcertPhoto]
    public var selectedConcert: ConcertCandidate?
    public var selectedSetlist: ConcertSetlist?
    public var rawMatchesByVideoID: [UUID: [RawRecognitionMatch]]
    public var currentStage: RecognitionStage
    /// Concert clusters found by timestamp grouping. Empty for legacy
    /// records and for batches analyzed before clustering ran.
    public var clusters: [ConcertClusterAssignment]
    /// Label used when this record's concert could not be identified.
    public var fallbackTitle: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        videos: [ConcertVideo],
        photos: [ConcertPhoto] = [],
        selectedConcert: ConcertCandidate? = nil,
        selectedSetlist: ConcertSetlist? = nil,
        rawMatchesByVideoID: [UUID: [RawRecognitionMatch]] = [:],
        currentStage: RecognitionStage = .idle,
        clusters: [ConcertClusterAssignment] = [],
        fallbackTitle: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.videos = videos
        self.photos = photos
        self.selectedConcert = selectedConcert
        self.selectedSetlist = selectedSetlist
        self.rawMatchesByVideoID = rawMatchesByVideoID
        self.currentStage = currentStage
        self.clusters = clusters
        self.fallbackTitle = fallbackTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case videos
        case photos
        case selectedConcert
        case selectedSetlist
        case rawMatchesByVideoID
        case currentStage
        case clusters
        case fallbackTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.videos = try container.decode([ConcertVideo].self, forKey: .videos)
        self.photos = try container.decodeIfPresent([ConcertPhoto].self, forKey: .photos) ?? []
        self.selectedConcert = try container.decodeIfPresent(ConcertCandidate.self, forKey: .selectedConcert)
        self.selectedSetlist = try container.decodeIfPresent(ConcertSetlist.self, forKey: .selectedSetlist)
        self.rawMatchesByVideoID = try container.decodeIfPresent([UUID: [RawRecognitionMatch]].self, forKey: .rawMatchesByVideoID) ?? [:]
        self.currentStage = try container.decode(RecognitionStage.self, forKey: .currentStage)
        self.clusters = try container.decodeIfPresent([ConcertClusterAssignment].self, forKey: .clusters) ?? []
        self.fallbackTitle = try container.decodeIfPresent(String.self, forKey: .fallbackTitle)
    }

    /// Splits this record into one sub-record per concert cluster.
    ///
    /// Each sub-record uses its cluster's id, media subset, per-cluster
    /// concert/setlist selection, and fallback title, so each cluster can be
    /// persisted as its own concert. Records without clusters (legacy or
    /// single-concert flow) return `[self]`, preserving existing behavior.
    public func perClusterAnalysisRecords() -> [AnalysisRecord] {
        // No clusters: legacy record, keep as-is.
        guard !clusters.isEmpty else { return [self] }

        // Single cluster: keep this record's identity (so history, results,
        // and library matching behave exactly as before clustering existed),
        // folding in the cluster's concert selection.
        if clusters.count == 1 {
            var single = self
            single.selectedConcert = selectedConcert ?? clusters[0].selectedConcert
            single.selectedSetlist = selectedSetlist ?? clusters[0].selectedSetlist
            single.fallbackTitle = fallbackTitle ?? (clusters[0].fallbackLabel.isEmpty ? nil : clusters[0].fallbackLabel)
            return [single]
        }

        return clusters.map { cluster in
            let videoIDSet = Set(cluster.videoIDs)
            let photoIDSet = Set(cluster.photoIDs)
            let clusterVideos = videos.filter { videoIDSet.contains($0.id) }
            let clusterPhotos = photos.filter { photoIDSet.contains($0.id) }
            let clusterMatches = rawMatchesByVideoID.filter { videoIDSet.contains($0.key) }
            return AnalysisRecord(
                id: cluster.id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                videos: clusterVideos,
                photos: clusterPhotos,
                selectedConcert: cluster.selectedConcert,
                selectedSetlist: cluster.selectedSetlist,
                rawMatchesByVideoID: clusterMatches,
                currentStage: currentStage,
                clusters: [],
                fallbackTitle: cluster.fallbackLabel.isEmpty ? nil : cluster.fallbackLabel
            )
        }
    }
}

public protocol AnalysisHistoryStoring {
    func loadRecords() throws -> [AnalysisRecord]
    func saveRecords(_ records: [AnalysisRecord]) throws
    func deleteRecord(id: UUID) throws
}

public final class JSONAnalysisHistoryStore: AnalysisHistoryStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loadRecords() throws -> [AnalysisRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([AnalysisRecord].self, from: data)
    }

    public func saveRecords(_ records: [AnalysisRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func deleteRecord(id: UUID) throws {
        var records = try loadRecords()
        records.removeAll { $0.id == id }
        try saveRecords(records)
    }
}
