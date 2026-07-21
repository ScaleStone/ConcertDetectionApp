import XCTest
@testable import ConcertSongFinderCore

final class MediaLibraryItemsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func video(hoursFromBase: Double?, segments: [SongSegment]) -> ConcertVideo {
        ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"),
            fileName: "v.mov",
            createdAt: hoursFromBase.map { base.addingTimeInterval($0 * 3600) },
            duration: 300,
            location: nil,
            segments: segments
        )
    }

    private func segment(title: String, artist: String = "Baby Keem", status: SegmentStatus = .identified, start: TimeInterval = 0) -> SongSegment {
        SongSegment(
            startTime: start,
            endTime: start + 60,
            status: status,
            primaryCandidate: SongCandidate(
                song: SongIdentity(id: "\(title)-\(artist)", title: title, artist: artist),
                setlistOccurrenceID: nil,
                evidenceScore: 1,
                confidenceLabel: .strong,
                reasons: []
            )
        )
    }

    private func makeSetlist(titles: [String], artist: String = "Baby Keem") -> ConcertSetlist {
        ConcertSetlist(
            id: "sl",
            artistName: artist,
            venueName: nil,
            eventDate: nil,
            occurrences: titles.enumerated().map { index, title in
                SetlistOccurrence(
                    id: "occ-\(index)",
                    setlistID: "sl",
                    setNumber: 0,
                    songIndex: index,
                    overallIndex: index,
                    title: title,
                    normalizedTitle: TextNormalizer.normalizeSongTitle(title),
                    artist: artist
                )
            },
            attributionURL: nil,
            versionID: "v1"
        )
    }

    func testMultiSongVideoProducesOneItemPerSong() {
        let videos = [video(hoursFromBase: 0, segments: [
            segment(title: "vent", start: 0),
            segment(title: "ORANGE SODA", start: 100)
        ])]
        let items = ConcertMediaGrouping.libraryItems(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.compactMap(\.songTitle)), ["vent", "ORANGE SODA"])
    }

    func testSameSongSegmentsDedupeToOneItem() {
        let videos = [video(hoursFromBase: 0, segments: [
            segment(title: "vent", start: 0),
            segment(title: "vent", start: 200)
        ])]
        let items = ConcertMediaGrouping.libraryItems(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(items.count, 1)
    }

    func testUnidentifiedVideoAppearsAsUnknown() {
        let videos = [video(hoursFromBase: 0, segments: [
            SongSegment(startTime: 0, endTime: 60, status: .unknown, primaryCandidate: nil)
        ])]
        let items = ConcertMediaGrouping.libraryItems(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].songTitle)
        XCTAssertEqual(items[0].displayLabel, "Unknown")
    }

    func testSetlistCleanTitlePreferredOverShazamQualifier() {
        let videos = [video(hoursFromBase: 0, segments: [
            segment(title: "Dramatic Girl (feat. Che Ecru)")
        ])]
        let items = ConcertMediaGrouping.libraryItems(
            videos: videos,
            photos: [],
            setlist: makeSetlist(titles: ["Dramatic Girl"])
        )
        XCTAssertEqual(items[0].songTitle, "Dramatic Girl")
    }

    func testPhotosLabeledFromPrimaryCandidate() {
        let photo = ConcertPhoto(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/p.jpg"),
            fileName: "p.jpg",
            createdAt: base,
            location: nil,
            classificationStatus: .identified,
            primaryCandidate: SongCandidate(
                song: SongIdentity(id: "x", title: "family ties", artist: "Baby Keem"),
                setlistOccurrenceID: nil,
                evidenceScore: 1,
                confidenceLabel: .strong,
                reasons: []
            )
        )
        let items = ConcertMediaGrouping.libraryItems(videos: [], photos: [photo], setlist: nil)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].songTitle, "family ties")
    }

    func testItemsSortByCaptureTimeWithUndatedLast() {
        let late = video(hoursFromBase: 2, segments: [segment(title: "Later Song")])
        let early = video(hoursFromBase: 0, segments: [segment(title: "Early Song")])
        let undated = video(hoursFromBase: nil, segments: [segment(title: "Undated Song")])
        let items = ConcertMediaGrouping.libraryItems(videos: [late, early, undated], photos: [], setlist: nil)
        XCTAssertEqual(items.map(\.songTitle), ["Early Song", "Later Song", "Undated Song"])
    }
}
