import ConcertSongFinderCore
import Foundation

@MainActor
final class ResultsViewModel: ObservableObject {
    @Published var record: AnalysisRecord
    @Published var selectedCorrection: SegmentCorrectionSelection?
    @Published var errorMessage: String?

    private let environment: AppEnvironment

    init(record: AnalysisRecord, environment: AppEnvironment) {
        self.record = record
        self.environment = environment
        AppLog.mediaClassification.info("ResultsViewModel initialized record=\(record.id.uuidString, privacy: .public) videos=\(record.videos.count, privacy: .public) photos=\(record.photos.count, privacy: .public) photoStatuses=\(record.photos.map { $0.classificationStatus.rawValue }.joined(separator: ","), privacy: .public)")
    }

    func applyCorrection(_ correction: SegmentCorrection) {
        guard let videoIndex = record.videos.firstIndex(where: { $0.id == correction.videoID }),
              let segmentIndex = record.videos[videoIndex].segments.firstIndex(where: { $0.id == correction.segmentID }) else {
            return
        }

        switch correction.action {
        case .confirmCandidate(let candidate):
            record.videos[videoIndex].segments[segmentIndex].primaryCandidate = candidate
            record.videos[videoIndex].segments[segmentIndex].status = .userConfirmed
            record.videos[videoIndex].segments[segmentIndex].evidence.isUserConfirmed = true
            record.videos[videoIndex].segments[segmentIndex].evidence.classificationSource = .userCorrection
        case .markSpeech:
            record.videos[videoIndex].segments[segmentIndex].primaryCandidate = nil
            record.videos[videoIndex].segments[segmentIndex].alternativeCandidates = []
            record.videos[videoIndex].segments[segmentIndex].status = .speech
            record.videos[videoIndex].segments[segmentIndex].evidence.isUserConfirmed = true
            record.videos[videoIndex].segments[segmentIndex].evidence.classificationSource = .userCorrection
        case .markUnknown:
            record.videos[videoIndex].segments[segmentIndex].primaryCandidate = nil
            record.videos[videoIndex].segments[segmentIndex].alternativeCandidates = []
            record.videos[videoIndex].segments[segmentIndex].status = .unknown
            record.videos[videoIndex].segments[segmentIndex].evidence.isUserConfirmed = true
            record.videos[videoIndex].segments[segmentIndex].evidence.classificationSource = .userCorrection
        case .adjustBoundary(let start, let end):
            record.videos[videoIndex].segments[segmentIndex].startTime = start
            record.videos[videoIndex].segments[segmentIndex].endTime = end
            record.videos[videoIndex].segments[segmentIndex].evidence.isUserConfirmed = true
            record.videos[videoIndex].segments[segmentIndex].evidence.classificationSource = .userCorrection
        }

        rerunAlignmentAfterCorrection()
        persist()
        AppLog.analysis.info("Applied segment correction video=\(correction.videoID.uuidString, privacy: .public) segment=\(correction.segmentID.uuidString, privacy: .public)")
    }

    func deleteHistory() {
        do {
            try environment.historyStore.deleteRecord(id: record.id)
            // Multi-cluster analyses may have produced several concerts; find
            // and delete each one (by id first, then by concert match).
            let concerts = try environment.concertLibraryStore.loadConcerts()
            var deletedConcertIDs: Set<UUID> = []
            for subRecord in record.perClusterAnalysisRecords() {
                let matchingConcert = ConcertRecord.findMatch(
                    for: subRecord,
                    in: concerts.filter { !deletedConcertIDs.contains($0.id) }
                )
                if let matchingConcert {
                    try environment.concertLibraryStore.deleteConcert(id: matchingConcert.id)
                    deletedConcertIDs.insert(matchingConcert.id)
                }
            }
            cleanUpOrphanedMediaFiles(deletedConcertIDs: deletedConcertIDs)
            AppLog.analysis.info("Deleted saved analysis record=\(self.record.id.uuidString, privacy: .public) concerts=\(deletedConcertIDs.count, privacy: .public)")
        } catch {
            errorMessage = "Could not delete saved analysis."
            AppLog.analysis.error("Failed to delete saved analysis record=\(self.record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes this record's imported media files from the app container
    /// unless another saved record or concert still references them.
    private func cleanUpOrphanedMediaFiles(deletedConcertIDs: Set<UUID>) {
        let candidateURLs = Set(record.videos.map(\.localURL) + record.photos.map(\.localURL))
        guard !candidateURLs.isEmpty else { return }

        var referencedPaths: Set<String> = []
        if let remainingRecords = try? environment.historyStore.loadRecords() {
            for other in remainingRecords where other.id != record.id {
                referencedPaths.formUnion(other.videos.map(\.localURL.path))
                referencedPaths.formUnion(other.photos.map(\.localURL.path))
            }
        }
        if let remainingConcerts = try? environment.concertLibraryStore.loadConcerts() {
            for concert in remainingConcerts where !deletedConcertIDs.contains(concert.id) {
                referencedPaths.formUnion(concert.videos.map(\.localURL.path))
                referencedPaths.formUnion(concert.photos.map(\.localURL.path))
            }
        }

        for url in candidateURLs where !referencedPaths.contains(url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                AppLog.analysis.info("Removed orphaned media file \(url.lastPathComponent, privacy: .public)")
            } catch {
                AppLog.analysis.error("Could not remove orphaned media file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rerunAlignmentAfterCorrection() {
        guard let setlist = record.selectedSetlist else { return }
        let observations = record.videos.enumerated().flatMap { videoIndex, video in
            video.segments.compactMap { segment -> SongObservation? in
                guard let candidate = segment.primaryCandidate,
                      [.identified, .likely, .userConfirmed].contains(segment.status) else {
                    return nil
                }
                return SongObservation(
                    videoID: video.id,
                    segmentID: segment.id,
                    videoOrder: videoIndex,
                    segmentStart: segment.startTime,
                    segmentEnd: segment.endTime,
                    song: candidate.song,
                    confidenceLabel: candidate.confidenceLabel,
                    isUserConfirmed: segment.evidence.isUserConfirmed
                )
            }
        }
        _ = environment.alignmentService.align(observations: observations, to: setlist.occurrences)
    }

    private func persist() {
        do {
            var records = try environment.historyStore.loadRecords()
            records.removeAll { $0.id == record.id }
            record.updatedAt = Date()
            records.append(record)
            try environment.historyStore.saveRecords(records)
            syncConcertLibrary()
            AppLog.analysis.info("Persisted results record=\(self.record.id.uuidString, privacy: .public) videoCount=\(self.record.videos.count, privacy: .public) photoCount=\(self.record.photos.count, privacy: .public)")
        } catch {
            errorMessage = "Could not save corrections."
            AppLog.analysis.error("Failed to persist results record=\(self.record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the concert library in sync with user corrections so
    /// My Concerts reflects the latest segment assignments. Multi-cluster
    /// analyses sync each cluster into its own concert.
    private func syncConcertLibrary() {
        do {
            let concerts = try environment.concertLibraryStore.loadConcerts()
            for subRecord in record.perClusterAnalysisRecords() {
                guard let existing = ConcertRecord.findMatch(for: subRecord, in: concerts) else {
                    continue
                }
                let updated = existing.merged(with: subRecord)
                try environment.concertLibraryStore.upsertConcert(updated)
                AppLog.concertLibrary.info("Synced corrections into concert library concert=\(updated.id.uuidString, privacy: .public) record=\(self.record.id.uuidString, privacy: .public)")
            }
        } catch {
            AppLog.concertLibrary.error("Failed to sync corrections into concert library record=\(self.record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

struct SegmentCorrectionSelection: Identifiable {
    let id = UUID()
    let videoID: UUID
    let segment: SongSegment
}

struct SegmentCorrection {
    let videoID: UUID
    let segmentID: UUID
    let action: SegmentCorrectionAction
}

enum SegmentCorrectionAction {
    case confirmCandidate(SongCandidate)
    case markSpeech
    case markUnknown
    case adjustBoundary(start: TimeInterval, end: TimeInterval)
}
