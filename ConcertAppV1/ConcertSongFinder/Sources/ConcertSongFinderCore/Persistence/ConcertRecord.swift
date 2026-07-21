import Foundation
import os

private enum ConcertLibraryLog {
    static let persistence = Logger(subsystem: "ConcertSongFinderCore", category: "concert-library")
}

public struct ConcertRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var selectedConcert: ConcertCandidate?
    public var selectedSetlist: ConcertSetlist?
    public var videos: [ConcertVideo]
    public var photos: [ConcertPhoto]
    public var rawMatchesByVideoID: [UUID: [RawRecognitionMatch]]
    public var currentStage: RecognitionStage
    /// Label used when no concert/setlist was identified (e.g. "Artist — date").
    public var fallbackTitle: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedConcert: ConcertCandidate? = nil,
        selectedSetlist: ConcertSetlist? = nil,
        videos: [ConcertVideo] = [],
        photos: [ConcertPhoto] = [],
        rawMatchesByVideoID: [UUID: [RawRecognitionMatch]] = [:],
        currentStage: RecognitionStage = .idle,
        fallbackTitle: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedConcert = selectedConcert
        self.selectedSetlist = selectedSetlist
        self.videos = videos
        self.photos = photos
        self.rawMatchesByVideoID = rawMatchesByVideoID
        self.currentStage = currentStage
        self.fallbackTitle = fallbackTitle
    }

    public init(analysisRecord: AnalysisRecord) {
        self.id = analysisRecord.id
        self.createdAt = analysisRecord.createdAt
        self.updatedAt = analysisRecord.updatedAt
        self.selectedConcert = analysisRecord.selectedConcert
        self.selectedSetlist = analysisRecord.selectedSetlist
        self.videos = analysisRecord.videos
        self.photos = analysisRecord.photos
        self.rawMatchesByVideoID = analysisRecord.rawMatchesByVideoID
        self.currentStage = analysisRecord.currentStage
        self.fallbackTitle = analysisRecord.fallbackTitle
    }

    public var displayTitle: String {
        selectedSetlist?.artistName
            ?? selectedConcert?.artistName
            ?? fallbackTitle
            ?? "Untitled Concert"
    }

    public var displaySubtitle: String {
        var parts: [String] = []
        if let eventDate = selectedSetlist?.eventDate ?? selectedConcert?.eventDate {
            // Backend event dates are calendar dates encoded as UTC midnight;
            // format them in UTC so they never shift a day in local time.
            parts.append(Self.utcDateFormatter.string(from: eventDate))
        } else if let mediaDate = (videos.compactMap(\.createdAt) + photos.compactMap(\.createdAt)).min() {
            parts.append(Self.dateFormatter.string(from: mediaDate))
        }
        if let venue = selectedSetlist?.venueName ?? selectedConcert?.venueName {
            parts.append(venue)
        }
        return parts.joined(separator: " • ")
    }

    public var concertDate: Date? {
        selectedSetlist?.eventDate
            ?? selectedConcert?.eventDate
            ?? (videos.compactMap(\.createdAt) + photos.compactMap(\.createdAt)).min()
    }

    public func matches(analysisRecord: AnalysisRecord, calendar: Calendar = .current) -> Bool {
        guard let incomingArtist = Self.normalizedArtist(analysisRecord.selectedSetlist?.artistName ?? analysisRecord.selectedConcert?.artistName),
              let existingArtist = Self.normalizedArtist(selectedSetlist?.artistName ?? selectedConcert?.artistName),
              incomingArtist == existingArtist else {
            return false
        }

        let incomingEventDate = analysisRecord.selectedSetlist?.eventDate ?? analysisRecord.selectedConcert?.eventDate
        let incomingMediaDate = analysisRecord.videos.compactMap(\.createdAt).min() ?? analysisRecord.photos.compactMap(\.createdAt).min()
        guard let incomingDay = Self.calendarDay(eventDate: incomingEventDate, mediaDate: incomingMediaDate, localCalendar: calendar) else {
            return false
        }

        let existingEventDate = selectedSetlist?.eventDate ?? selectedConcert?.eventDate
        let existingMediaDate = (videos.compactMap(\.createdAt) + photos.compactMap(\.createdAt)).min()
        guard let existingDay = Self.calendarDay(eventDate: existingEventDate, mediaDate: existingMediaDate, localCalendar: calendar) else {
            return false
        }

        return incomingDay == existingDay
    }

    /// Fully automatic concert assignment for a completed analysis
    /// (sub-)record, tiered by confidence:
    /// 1. Same record/cluster id (re-analysis) always wins.
    /// 2. Identified uploads match an existing concert by artist + calendar
    ///    day; failing that, they adopt an unidentified concert from the
    ///    same evening (upgrading it with the identification).
    /// 3. Unidentified uploads join whichever concert's media sits within
    ///    the same-evening time window.
    /// Returns nil when a new concert should be created.
    public static func findMatch(
        for analysisRecord: AnalysisRecord,
        in concerts: [ConcertRecord],
        gapThreshold: TimeInterval = ConcertClusterer.defaultGapThreshold
    ) -> ConcertRecord? {
        if let byID = concerts.first(where: { $0.id == analysisRecord.id }) {
            return byID
        }

        let incomingArtist = normalizedArtist(analysisRecord.selectedSetlist?.artistName ?? analysisRecord.selectedConcert?.artistName)
        if incomingArtist != nil {
            if let artistAndDay = concerts.first(where: { $0.matches(analysisRecord: analysisRecord) }) {
                return artistAndDay
            }
            // Same evening, previously unidentified concert: claim it so the
            // identification upgrades the existing entry instead of creating
            // a duplicate.
            return concerts.first { concert in
                normalizedArtist(concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName) == nil
                    && isWithinSameEvening(concert, analysisRecord: analysisRecord, gapThreshold: gapThreshold)
            }
        }

        // Unidentified upload: assign purely by timestamp proximity.
        return concerts.first { isWithinSameEvening($0, analysisRecord: analysisRecord, gapThreshold: gapThreshold) }
    }

    /// The time span covered by this concert's media (capture instants,
    /// extended by video durations).
    public var mediaTimeRange: ClosedRange<Date>? {
        Self.mediaTimeRange(videos: videos, photos: photos)
    }

    private static func mediaTimeRange(videos: [ConcertVideo], photos: [ConcertPhoto]) -> ClosedRange<Date>? {
        var dates: [Date] = []
        for video in videos {
            if let createdAt = video.createdAt {
                dates.append(createdAt)
                dates.append(createdAt.addingTimeInterval(max(video.duration, 0)))
            }
        }
        for photo in photos {
            if let createdAt = photo.createdAt {
                dates.append(createdAt)
            }
        }
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }
        return earliest...latest
    }

    private static func isWithinSameEvening(
        _ concert: ConcertRecord,
        analysisRecord: AnalysisRecord,
        gapThreshold: TimeInterval
    ) -> Bool {
        guard let existingRange = concert.mediaTimeRange,
              let incomingRange = mediaTimeRange(videos: analysisRecord.videos, photos: analysisRecord.photos) else {
            return false
        }
        // Gap between the two ranges (negative when they overlap).
        let gap = max(existingRange.lowerBound, incomingRange.lowerBound)
            .timeIntervalSince(min(existingRange.upperBound, incomingRange.upperBound))
        return gap <= gapThreshold
    }

    /// Event dates from the backend are calendar dates stored as UTC midnight
    /// and must be read with a UTC calendar; media timestamps are real
    /// instants and use the local calendar. Comparing the resulting
    /// day components pairs the two correctly without off-by-one-day drift.
    private static func calendarDay(eventDate: Date?, mediaDate: Date?, localCalendar: Calendar) -> DateComponents? {
        if let eventDate {
            return utcCalendar.dateComponents([.year, .month, .day], from: eventDate)
        }
        if let mediaDate {
            return localCalendar.dateComponents([.year, .month, .day], from: mediaDate)
        }
        return nil
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    public func merged(with analysisRecord: AnalysisRecord) -> ConcertRecord {
        var merged = self
        merged.updatedAt = Date()
        merged.selectedConcert = selectedConcert ?? analysisRecord.selectedConcert
        merged.selectedSetlist = selectedSetlist ?? analysisRecord.selectedSetlist
        merged.fallbackTitle = fallbackTitle ?? analysisRecord.fallbackTitle
        merged.currentStage = analysisRecord.currentStage
        merged.videos = Self.mergedVideos(existing: videos, incoming: analysisRecord.videos)
        merged.photos = Self.mergedPhotos(existing: photos, incoming: analysisRecord.photos)
        merged.rawMatchesByVideoID.merge(analysisRecord.rawMatchesByVideoID) { _, incoming in incoming }
        return merged
    }

    public func analysisRecord(appending mediaImport: ConcertMediaImport? = nil) -> AnalysisRecord {
        var combinedVideos = videos
        var combinedPhotos = photos
        if let mediaImport {
            combinedVideos = Self.mergedVideos(existing: combinedVideos, incoming: mediaImport.videos)
            combinedPhotos = Self.mergedPhotos(existing: combinedPhotos, incoming: mediaImport.photos)
        }
        return AnalysisRecord(
            id: id,
            createdAt: createdAt,
            updatedAt: Date(),
            videos: combinedVideos,
            photos: combinedPhotos,
            selectedConcert: selectedConcert,
            selectedSetlist: selectedSetlist,
            rawMatchesByVideoID: rawMatchesByVideoID,
            currentStage: currentStage
        )
    }

    public static func newConcert(from analysisRecord: AnalysisRecord) -> ConcertRecord {
        ConcertRecord(analysisRecord: analysisRecord)
    }

    private static func mergedVideos(existing: [ConcertVideo], incoming: [ConcertVideo]) -> [ConcertVideo] {
        var result = existing
        var seenKeys = Set(result.map(videoIdentityKey))
        for video in incoming {
            // Same video re-analyzed or corrected: take the newer copy so
            // updated segments and statuses propagate into the library.
            if let existingIndex = result.firstIndex(where: { $0.id == video.id }) {
                result[existingIndex] = video
                continue
            }
            let key = videoIdentityKey(video)
            guard seenKeys.insert(key).inserted else {
                ConcertLibraryLog.persistence.info("Skipped duplicate video while merging concert media video=\(video.id.uuidString, privacy: .public) file=\(video.fileName, privacy: .public) key=\(key, privacy: .public)")
                continue
            }
            result.append(video)
        }
        return result.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.originalSelectionIndex < $1.originalSelectionIndex
            }
        }
    }

    private static func mergedPhotos(existing: [ConcertPhoto], incoming: [ConcertPhoto]) -> [ConcertPhoto] {
        var result = existing
        var seenKeys = Set(result.map(photoIdentityKey))
        for photo in incoming {
            // Same photo re-classified or corrected: take the newer copy.
            if let existingIndex = result.firstIndex(where: { $0.id == photo.id }) {
                result[existingIndex] = photo
                continue
            }
            let key = photoIdentityKey(photo)
            guard seenKeys.insert(key).inserted else {
                ConcertLibraryLog.persistence.info("Skipped duplicate photo while merging concert media photo=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public) key=\(key, privacy: .public)")
                continue
            }
            result.append(photo)
        }
        return result.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.originalSelectionIndex < $1.originalSelectionIndex
            }
        }
    }

    private static func videoIdentityKey(_ video: ConcertVideo) -> String {
        if let localIdentifier = nonEmpty(video.localIdentifier) {
            return "asset:\(localIdentifier)"
        }

        if let createdAt = video.createdAt {
            let timestamp = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())
            let duration = Int64((video.duration * 1_000).rounded())
            return "video-metadata:\(timestamp):\(duration)"
        }

        return "video-url:\(video.localURL.standardizedFileURL.path)"
    }

    private static func photoIdentityKey(_ photo: ConcertPhoto) -> String {
        if let localIdentifier = nonEmpty(photo.localIdentifier) {
            return "asset:\(localIdentifier)"
        }

        if let createdAt = photo.createdAt {
            let timestamp = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())
            return "photo-metadata:\(timestamp)"
        }

        return "photo-url:\(photo.localURL.standardizedFileURL.path)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func normalizedArtist(_ value: String?) -> String? {
        let normalized = TextNormalizer.normalizeText(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let utcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

public protocol ConcertLibraryStoring {
    func loadConcerts() throws -> [ConcertRecord]
    func saveConcerts(_ concerts: [ConcertRecord]) throws
    func upsertConcert(_ concert: ConcertRecord) throws
    func deleteConcert(id: UUID) throws
}

public final class JSONConcertLibraryStore: ConcertLibraryStoring {
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

    public func loadConcerts() throws -> [ConcertRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            ConcertLibraryLog.persistence.info("Concert library load returned empty because file is missing path=\(self.fileURL.lastPathComponent, privacy: .public)")
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let concerts = try decoder.decode([ConcertRecord].self, from: data)
        ConcertLibraryLog.persistence.info("Concert library loaded count=\(concerts.count, privacy: .public) path=\(self.fileURL.lastPathComponent, privacy: .public)")
        return concerts
    }

    public func saveConcerts(_ concerts: [ConcertRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(concerts)
        try data.write(to: fileURL, options: [.atomic])
        ConcertLibraryLog.persistence.info("Concert library saved count=\(concerts.count, privacy: .public) path=\(self.fileURL.lastPathComponent, privacy: .public)")
    }

    public func upsertConcert(_ concert: ConcertRecord) throws {
        var concerts = try loadConcerts()
        concerts.removeAll { $0.id == concert.id }
        concerts.append(concert)
        try saveConcerts(concerts.sorted { $0.updatedAt > $1.updatedAt })
        ConcertLibraryLog.persistence.info("Concert library upserted concert=\(concert.id.uuidString, privacy: .public) videos=\(concert.videos.count, privacy: .public) photos=\(concert.photos.count, privacy: .public)")
    }

    public func deleteConcert(id: UUID) throws {
        var concerts = try loadConcerts()
        concerts.removeAll { $0.id == id }
        try saveConcerts(concerts)
        ConcertLibraryLog.persistence.info("Concert library deleted concert=\(id.uuidString, privacy: .public)")
    }
}
