import XCTest
@testable import ConcertSongFinderCore

final class OrderingAndPersistenceTests: XCTestCase {
    func testMissingRecordingTimestampFallsBackToSelectionOrder() {
        let first = video(index: 0, createdAt: nil)
        let second = video(index: 1, createdAt: nil)
        XCTAssertEqual(ConcertVideoOrdering.sortedChronologically([second, first]).map(\.id), [first.id, second.id])
    }

    func testVideosImportedOutOfOrderSortByTimestamp() {
        let later = video(index: 0, createdAt: Date(timeIntervalSince1970: 200))
        let earlier = video(index: 1, createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(ConcertVideoOrdering.sortedChronologically([later, earlier]).map(\.id), [earlier.id, later.id])
    }

    func testDuplicateSelectedVideoIsRemovedByLocalIdentifier() {
        let first = video(localIdentifier: "asset-1", index: 0)
        let duplicate = video(localIdentifier: "asset-1", index: 1)
        XCTAssertEqual(ConcertVideoOrdering.removingDuplicates([first, duplicate]).count, 1)
    }

    func testAnalysisCancellationAndResumeRecordPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let store = JSONAnalysisHistoryStore(fileURL: url)
        let record = AnalysisRecord(videos: [video(index: 0)], currentStage: .canceled)
        try store.saveRecords([record])
        let loaded = try store.loadRecords()
        XCTAssertEqual(loaded.first?.currentStage, .canceled)
        XCTAssertEqual(loaded.first?.videos.count, 1)
        try? FileManager.default.removeItem(at: url)
    }

    func testNoAudioTrackErrorIsRepresentable() {
        XCTAssertEqual(ConcertSongFinderError.noAudioTrack.errorDescription, "This video does not contain an audio track.")
    }

    func testBackendAndProviderFailuresAreTyped() {
        XCTAssertEqual(ConcertSongFinderError.backendUnavailable.errorDescription, "The ConcertSongFinder backend is unavailable.")
        XCTAssertEqual(ConcertSongFinderError.lyricProviderFailure.errorDescription, "The lyric provider could not complete the request.")
    }

    func testSetlistUpdatedToNewVersionIsPersisted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let store = JSONAnalysisHistoryStore(fileURL: url)
        let setlist = ConcertSetlist(
            id: "set",
            artistName: "Artist",
            venueName: "Venue",
            eventDate: nil,
            occurrences: [occurrence("Song A", overall: 0)],
            attributionURL: nil,
            versionID: "v2"
        )
        let record = AnalysisRecord(videos: [video(index: 0)], selectedSetlist: setlist)
        try store.saveRecords([record])
        XCTAssertEqual(try store.loadRecords().first?.selectedSetlist?.versionID, "v2")
        try? FileManager.default.removeItem(at: url)
    }
}

func video(localIdentifier: String? = nil, index: Int, createdAt: Date? = nil) -> ConcertVideo {
    ConcertVideo(
        localIdentifier: localIdentifier,
        localURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"),
        fileName: "video-\(index).mov",
        createdAt: createdAt,
        duration: 30,
        location: nil,
        originalSelectionIndex: index
    )
}
