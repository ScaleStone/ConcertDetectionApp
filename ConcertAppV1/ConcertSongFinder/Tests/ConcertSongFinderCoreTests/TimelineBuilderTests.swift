import XCTest
@testable import ConcertSongFinderCore

final class TimelineBuilderTests: XCTestCase {
    private let builder = DefaultTimelineBuilder()

    func testOneClearSongAcrossEntireVideo() {
        let a = song("Song A")
        let segments = builder.buildTimeline(duration: 40, rawMatches: [
            match(a, 0, 15), match(a, 5, 20), match(a, 10, 25), match(a, 15, 30)
        ])
        XCTAssertEqual(segments.filter { $0.status == .identified }.count, 1)
        XCTAssertEqual(segments.first?.primaryCandidate?.song.title, "Song A")
        XCTAssertEqual(segments.first?.startTime, 0)
        XCTAssertEqual(segments.first?.endTime, 40)
    }

    func testTwoSongsWithCleanTransition() {
        let a = song("Song A")
        let b = song("Song B")
        let segments = builder.buildTimeline(duration: 40, rawMatches: [
            match(a, 0, 15), match(a, 5, 20), match(a, 10, 25),
            match(b, 15, 30), match(b, 20, 35), match(b, 25, 40)
        ])
        XCTAssertTrue(segments.contains { $0.status == .transition })
        XCTAssertEqual(songTitles(in: segments), ["Song A", "Song A", "Song B"])
    }

    func testTwoSongsWithOverlappingCrossover() {
        let a = song("FE!N")
        let b = song("NO BYSTANDERS")
        let segments = builder.buildTimeline(duration: 58, rawMatches: [
            match(a, 0, 15), match(a, 5, 20), match(a, 10, 25),
            match(b, 18, 33), match(b, 23, 38), match(b, 28, 43)
        ])
        let transition = segments.first { $0.status == .transition }
        XCTAssertNotNil(transition)
        XCTAssertEqual(transition?.primaryCandidate?.song.title, "FE!N")
        XCTAssertEqual(transition?.alternativeCandidates.first?.song.title, "NO BYSTANDERS")
    }

    func testOneIsolatedFalseShazamMatchIsSmoothed() {
        let a = song("Song A")
        let b = song("Song B")
        let segments = builder.buildTimeline(duration: 35, rawMatches: [
            match(a, 0, 15), match(a, 5, 20), match(b, 10, 25), match(a, 15, 30), match(a, 20, 35)
        ])
        XCTAssertFalse(segments.contains { $0.primaryCandidate?.song.title == "Song B" })
        XCTAssertEqual(segments.filter { $0.primaryCandidate?.song.title == "Song A" }.count, 1)
    }

    func testThreeSongsInOneVideo() {
        let a = song("Song A")
        let b = song("Song B")
        let c = song("Song C")
        let segments = builder.buildTimeline(duration: 65, rawMatches: [
            match(a, 0, 15), match(a, 5, 20),
            match(b, 20, 35), match(b, 25, 40),
            match(c, 40, 55), match(c, 45, 60)
        ])
        XCTAssertEqual(songTitles(in: segments).filter { $0.hasPrefix("Song") }, ["Song A", "Song A", "Song B", "Song B", "Song C"])
    }

    func testSameSongReturningAfterAnotherSongDoesNotMerge() {
        let a = song("Song A")
        let b = song("Song B")
        let segments = builder.buildTimeline(duration: 60, rawMatches: [
            match(a, 0, 15), match(a, 5, 20),
            match(b, 20, 35), match(b, 25, 40),
            match(a, 40, 55), match(a, 45, 60)
        ])
        XCTAssertEqual(segments.filter { $0.primaryCandidate?.song.title == "Song A" && $0.status != .transition }.count, 2)
    }

    func testVideoShorterThanTenSecondsUsesCompleteWindow() {
        let windows = RecognitionWindowPlanner.windows(duration: 7)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, 0)
        XCTAssertEqual(windows[0].end, 7)
    }

    func testDefaultRecognitionWindowsStayWithinShazamQueryLimit() {
        let windows = RecognitionWindowPlanner.windows(duration: 22.603333)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.end - $0.start <= 12 })
    }

    func testNoShazamMatchPreservesUnknownSegment() {
        let segments = builder.buildTimeline(duration: 20, rawMatches: [])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.status, .unknown)
    }

    func testAdjacentSameSongSegmentsMergeAcrossTinyUnknownGapByIdentity() {
        let a = song("Song A", isrc: "US-AAA")
        let remaster = SongIdentity(id: "remaster", title: "Song A (Remastered)", artist: "Artist", album: nil, isrc: "US-AAA")
        let segments = builder.buildTimeline(duration: 30, rawMatches: [
            match(a, 0, 15), match(remaster, 15, 30)
        ])
        XCTAssertEqual(segments.filter { $0.primaryCandidate?.song.isrc == "US-AAA" }.count, 1)
    }

    func testSameTitleSegmentsDoNotMergeAcrossAnotherSong() {
        let a = song("Song A")
        let b = song("Song B")
        let segments = builder.buildTimeline(duration: 60, rawMatches: [
            match(a, 0, 15), match(a, 5, 20),
            match(b, 20, 35), match(b, 25, 40),
            match(a, 40, 55), match(a, 45, 60)
        ])
        XCTAssertEqual(segments.filter { $0.primaryCandidate?.song.title == "Song A" && $0.status != .transition }.count, 2)
    }

    func testUnknownTransitionRangePreserved() {
        let a = song("Song A")
        let b = song("Song B")
        let segments = builder.buildTimeline(duration: 40, rawMatches: [
            match(a, 0, 15), match(a, 5, 20), match(b, 20, 35), match(b, 25, 40)
        ])
        let transition = segments.first { $0.status == .transition }
        XCTAssertNotNil(transition)
        XCTAssertGreaterThan(transition?.endTime ?? 0, transition?.startTime ?? 0)
    }
}

func song(_ title: String, artist: String = "Artist", isrc: String? = nil) -> SongIdentity {
    SongIdentity(
        id: isrc ?? TextNormalizer.normalizedSongKey(title: title, artist: artist),
        title: title,
        artist: artist,
        album: nil,
        isrc: isrc
    )
}

func match(_ song: SongIdentity, _ start: TimeInterval, _ end: TimeInterval, strength: Double = 1) -> RawRecognitionMatch {
    RawRecognitionMatch(windowStart: start, windowEnd: end, song: song, strength: strength)
}

func songTitles(in segments: [SongSegment]) -> [String] {
    segments.compactMap { segment in
        if segment.status == .transition {
            return segment.primaryCandidate?.song.title
        }
        return segment.primaryCandidate?.song.title
    }
}
