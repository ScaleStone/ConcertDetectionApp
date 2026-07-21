import XCTest
@testable import ConcertSongFinderCore

final class ConcertMatchingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func video(hoursFromBase: Double, duration: TimeInterval = 60) -> ConcertVideo {
        ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"),
            fileName: "v.mov",
            createdAt: base.addingTimeInterval(hoursFromBase * 3600),
            duration: duration,
            location: nil
        )
    }

    private func setlist(artist: String) -> ConcertSetlist {
        ConcertSetlist(
            id: "sl-\(artist)",
            artistName: artist,
            venueName: nil,
            eventDate: nil,
            occurrences: [],
            attributionURL: nil,
            versionID: "v1"
        )
    }

    func testRecordIDMatchWinsRegardlessOfContent() {
        let record = AnalysisRecord(videos: [video(hoursFromBase: 0)])
        let concert = ConcertRecord(id: record.id, videos: [])
        XCTAssertEqual(ConcertRecord.findMatch(for: record, in: [concert])?.id, concert.id)
    }

    func testIdentifiedUploadMatchesConcertByArtistAndDay() {
        let concert = ConcertRecord(
            selectedSetlist: setlist(artist: "Baby Keem"),
            videos: [video(hoursFromBase: 0)]
        )
        let record = AnalysisRecord(
            videos: [video(hoursFromBase: 1)],
            selectedSetlist: setlist(artist: "Baby Keem")
        )
        XCTAssertEqual(ConcertRecord.findMatch(for: record, in: [concert])?.id, concert.id)
    }

    func testIdentifiedUploadAdoptsUnidentifiedSameEveningConcert() {
        let unidentified = ConcertRecord(videos: [video(hoursFromBase: 0)])
        let record = AnalysisRecord(
            videos: [video(hoursFromBase: 2)],
            selectedSetlist: setlist(artist: "Baby Keem")
        )
        XCTAssertEqual(ConcertRecord.findMatch(for: record, in: [unidentified])?.id, unidentified.id)
    }

    func testIdentifiedUploadDoesNotJoinDifferentArtistSameEvening() {
        let otherArtist = ConcertRecord(
            selectedSetlist: setlist(artist: "Don Toliver"),
            videos: [video(hoursFromBase: 0)]
        )
        let record = AnalysisRecord(
            videos: [video(hoursFromBase: 1)],
            selectedSetlist: setlist(artist: "Baby Keem")
        )
        XCTAssertNil(ConcertRecord.findMatch(for: record, in: [otherArtist]))
    }

    func testUnidentifiedUploadJoinsSameEveningConcertByTimestamp() {
        let concert = ConcertRecord(
            selectedSetlist: setlist(artist: "Baby Keem"),
            videos: [video(hoursFromBase: 0)]
        )
        let record = AnalysisRecord(videos: [video(hoursFromBase: 3)])
        XCTAssertEqual(ConcertRecord.findMatch(for: record, in: [concert])?.id, concert.id)
    }

    func testUnidentifiedUploadBeyondGapCreatesNewConcert() {
        let concert = ConcertRecord(videos: [video(hoursFromBase: 0)])
        let record = AnalysisRecord(videos: [video(hoursFromBase: 30)])
        XCTAssertNil(ConcertRecord.findMatch(for: record, in: [concert]))
    }

    func testUploadWithoutTimestampsCreatesNewConcert() {
        let concert = ConcertRecord(videos: [video(hoursFromBase: 0)])
        let undatedVideo = ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/undated.mov"),
            fileName: "undated.mov",
            createdAt: nil,
            duration: 60,
            location: nil
        )
        let record = AnalysisRecord(videos: [undatedVideo])
        XCTAssertNil(ConcertRecord.findMatch(for: record, in: [concert]))
    }
}
