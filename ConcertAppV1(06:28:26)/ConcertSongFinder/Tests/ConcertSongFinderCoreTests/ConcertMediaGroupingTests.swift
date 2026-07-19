import XCTest
@testable import ConcertSongFinderCore

final class ConcertMediaGroupingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func video(named name: String, hoursFromBase: Double?, segments: [SongSegment]) -> ConcertVideo {
        ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/\(name).mov"),
            fileName: "\(name).mov",
            createdAt: hoursFromBase.map { base.addingTimeInterval($0 * 3600) },
            duration: 60,
            location: nil,
            segments: segments
        )
    }

    private func segment(title: String, artist: String, status: SegmentStatus) -> SongSegment {
        SongSegment(
            startTime: 0,
            endTime: 30,
            status: status,
            primaryCandidate: SongCandidate(
                song: SongIdentity(id: TextNormalizer.normalizedSongKey(title: title, artist: artist), title: title, artist: artist),
                setlistOccurrenceID: nil,
                evidenceScore: 1,
                confidenceLabel: .strong,
                reasons: []
            )
        )
    }

    private func setlist(titles: [String], artist: String = "Main Act") -> ConcertSetlist {
        ConcertSetlist(
            id: "setlist-1",
            artistName: artist,
            venueName: nil,
            eventDate: nil,
            occurrences: titles.enumerated().map { index, title in
                SetlistOccurrence(
                    id: "occ-\(index)",
                    setlistID: "setlist-1",
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

    func testNoSetlistGroupsAllReliablyRecognizedSongs() {
        let videos = [
            video(named: "a", hoursFromBase: 0, segments: [segment(title: "Poppin", artist: "Rich Amiri", status: .identified)]),
            video(named: "b", hoursFromBase: 1, segments: [segment(title: "Poppin", artist: "Rich Amiri", status: .identified)]),
            video(named: "c", hoursFromBase: 2, segments: [segment(title: "One Call", artist: "Rich Amiri", status: .likely)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].song.title, "Poppin")
        XCTAssertEqual(groups[0].videoSegments.count, 2)
        XCTAssertEqual(groups[1].song.title, "One Call")
    }

    func testSetlistMatchedSongsAreExcluded() {
        let videos = [
            video(named: "onlist", hoursFromBase: 0, segments: [segment(title: "Dramatic Girl (feat. Che Ecru)", artist: "Baby Keem", status: .identified)]),
            video(named: "cover", hoursFromBase: 1, segments: [segment(title: "Surprise Cover", artist: "Baby Keem", status: .identified)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(
            videos: videos,
            photos: [],
            setlist: setlist(titles: ["Dramatic Girl"], artist: "Baby Keem")
        )
        XCTAssertEqual(groups.count, 1, "Songs matching the setlist (even with feat. qualifiers) belong to setlist groups")
        XCTAssertEqual(groups[0].song.title, "Surprise Cover")
    }

    func testWeakPossibleSegmentsDoNotFormGroups() {
        let videos = [
            video(named: "weak", hoursFromBase: 0, segments: [segment(title: "Maybe Song", artist: "Someone", status: .possible)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(videos: videos, photos: [], setlist: nil)
        XCTAssertTrue(groups.isEmpty)
    }

    func testFeatVariantsMergeIntoOneGroup() {
        let videos = [
            video(named: "a", hoursFromBase: 0, segments: [segment(title: "range brothers (feat. Kendrick Lamar)", artist: "Baby Keem", status: .identified)]),
            video(named: "b", hoursFromBase: 1, segments: [segment(title: "Range Brothers", artist: "Baby Keem", status: .identified)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].videoSegments.count, 2)
    }

    func testPhotosJoinMatchingRecognizedGroup() {
        let photo = ConcertPhoto(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/p.jpg"),
            fileName: "p.jpg",
            createdAt: base.addingTimeInterval(1800),
            location: nil,
            classificationStatus: .identified,
            primaryCandidate: SongCandidate(
                song: SongIdentity(id: "x", title: "Poppin", artist: "Rich Amiri"),
                setlistOccurrenceID: nil,
                evidenceScore: 1,
                confidenceLabel: .strong,
                reasons: []
            )
        )
        let videos = [
            video(named: "a", hoursFromBase: 0, segments: [segment(title: "Poppin", artist: "Rich Amiri", status: .identified)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(videos: videos, photos: [photo], setlist: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].photos.count, 1)
    }

    func testGroupsSortByEarliestMediaDate() {
        let videos = [
            video(named: "later", hoursFromBase: 2, segments: [segment(title: "Second Song", artist: "A", status: .identified)]),
            video(named: "earlier", hoursFromBase: 0, segments: [segment(title: "First Song", artist: "A", status: .identified)])
        ]
        let groups = ConcertMediaGrouping.recognizedSongGroups(videos: videos, photos: [], setlist: nil)
        XCTAssertEqual(groups.map(\.song.title), ["First Song", "Second Song"])
    }
}
