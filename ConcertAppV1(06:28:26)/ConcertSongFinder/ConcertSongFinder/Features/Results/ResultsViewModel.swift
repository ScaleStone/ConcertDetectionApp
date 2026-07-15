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
            try environment.concertLibraryStore.deleteConcert(id: record.id)
            AppLog.analysis.info("Deleted saved analysis and concert record=\(self.record.id.uuidString, privacy: .public)")
        } catch {
            errorMessage = "Could not delete saved analysis."
            AppLog.analysis.error("Failed to delete saved analysis record=\(self.record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
            AppLog.analysis.info("Persisted results record=\(self.record.id.uuidString, privacy: .public) videoCount=\(self.record.videos.count, privacy: .public) photoCount=\(self.record.photos.count, privacy: .public)")
        } catch {
            errorMessage = "Could not save corrections."
            AppLog.analysis.error("Failed to persist results record=\(self.record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
