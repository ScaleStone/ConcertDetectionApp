import XCTest
@testable import ConcertSongFinderCore

final class MediaClassificationTests: XCTestCase {
    private let classifier = DefaultMediaClassificationService()
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testPhotoInsideKnownSegmentIsIdentified() {
        let song = song("Song A")
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song, start: 0, end: 60, status: .identified)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(30))]
        )

        let classified = classifier.classify(record: record)

        XCTAssertEqual(classified.photos.first?.classificationStatus, .identified)
        XCTAssertEqual(classified.photos.first?.primaryCandidate?.song.title, "Song A")
        XCTAssertEqual(classified.photos.first?.concertTiming, .duringConcert)
    }

    func testPhotoBetweenSetlistAnchorsGetsFullBoundedOptions() {
        let selectedSetlist = setlist(titles: (1...10).map { "Song \($0)" })
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Song 4"), start: 0, end: 30, status: .identified)]
                ),
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("Song 8"), start: 0, end: 30, status: .identified)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(75))],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let photo = classified.photos[0]

        XCTAssertEqual(photo.classificationStatus, .possible)
        XCTAssertEqual(photo.evidence.classificationSource, .temporalPositioning)
        XCTAssertEqual(photo.evidence.boundedCandidateOptions.map(\.song.title), ["Song 4", "Song 5", "Song 6", "Song 7", "Song 8"])
        XCTAssertEqual(photo.primaryCandidate?.song.title, "Song 4")
        XCTAssertEqual(photo.concertTiming, .duringConcert)
    }

    func testPhotoBetweenSameSetlistAnchorGetsSingleLikelyOption() {
        let selectedSetlist = setlist(titles: (1...6).map { "Song \($0)" })
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Song 3"), start: 0, end: 30, status: .identified)]
                ),
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("Song 3"), start: 0, end: 30, status: .identified)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(75))],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let photo = classified.photos[0]

        XCTAssertEqual(photo.classificationStatus, .likely)
        XCTAssertEqual(photo.primaryCandidate?.song.title, "Song 3")
        XCTAssertEqual(photo.evidence.boundedCandidateOptions.map(\.song.title), ["Song 3"])
    }

    func testPhotoBeforeConcertIsLabeledBeforeConcert() {
        let song = song("Song A")
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song, start: 0, end: 60, status: .identified)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(-300))]
        )

        let classified = classifier.classify(record: record)

        XCTAssertEqual(classified.photos.first?.concertTiming, .beforeConcert)
        XCTAssertEqual(classified.photos.first?.classificationStatus, .unknown)
        XCTAssertNil(classified.photos.first?.primaryCandidate)
    }

    func testPhotoAfterConcertIsLabeledAfterConcert() {
        let song = song("Song A")
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song, start: 0, end: 60, status: .identified)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(240))]
        )

        let classified = classifier.classify(record: record)

        XCTAssertEqual(classified.photos.first?.concertTiming, .afterConcert)
        XCTAssertEqual(classified.photos.first?.classificationStatus, .unknown)
        XCTAssertNil(classified.photos.first?.primaryCandidate)
    }

    func testPhotoTimingWorksWithoutReliableSongAnchors() {
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [SongSegment(startTime: 0, endTime: 60, status: .unknown, primaryCandidate: nil)]
                )
            ],
            photos: [photo(createdAt: baseDate.addingTimeInterval(-60))]
        )

        let classified = classifier.classify(record: record)

        XCTAssertEqual(classified.photos.first?.concertTiming, .beforeConcert)
        XCTAssertNil(classified.photos.first?.primaryCandidate)
    }

    func testUnknownVideoBetweenSetlistAnchorsGetsFullBoundedOptions() {
        let selectedSetlist = setlist(titles: (1...10).map { "Song \($0)" })
        let unknown = video(
            createdAt: baseDate.addingTimeInterval(75),
            segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
        )
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Song 4"), start: 0, end: 30, status: .identified)]
                ),
                unknown,
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("Song 8"), start: 0, end: 30, status: .identified)]
                )
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let inferred = classified.videos[1].segments[0]

        XCTAssertEqual(inferred.status, .possible)
        XCTAssertEqual(inferred.evidence.classificationSource, .temporalPositioning)
        XCTAssertEqual(inferred.evidence.boundedCandidateOptions.map(\.song.title), ["Song 4", "Song 5", "Song 6", "Song 7", "Song 8"])
        XCTAssertEqual(inferred.primaryCandidate?.song.title, "Song 4")
    }

    func testUnknownVideoBeforeFirstResolvedAnchorUsesSetlistStartToNextAnchor() {
        let selectedSetlist = setlist(titles: (1...8).map { "Song \($0)" })
        let unknown = video(
            createdAt: baseDate,
            segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
        )
        let record = AnalysisRecord(
            videos: [
                unknown,
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("Song 4"), start: 0, end: 30, status: .identified)]
                )
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let inferred = classified.videos[0].segments[0]

        XCTAssertEqual(inferred.status, .possible)
        XCTAssertEqual(inferred.evidence.boundedCandidateOptions.map(\.song.title), ["Song 1", "Song 2", "Song 3", "Song 4"])
    }

    func testUnknownVideoAfterLastResolvedAnchorUsesPreviousAnchorToSetlistEnd() {
        let selectedSetlist = setlist(titles: (1...8).map { "Song \($0)" })
        let unknown = video(
            createdAt: baseDate.addingTimeInterval(120),
            segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
        )
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Song 5"), start: 0, end: 30, status: .identified)]
                ),
                unknown
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let inferred = classified.videos[1].segments[0]

        XCTAssertEqual(inferred.status, .possible)
        XCTAssertEqual(inferred.evidence.boundedCandidateOptions.map(\.song.title), ["Song 5", "Song 6", "Song 7", "Song 8"])
    }

    func testSimilarTitleAnchorNarrowsTemporalBounds() {
        let selectedSetlist = setlist(titles: ["Intro", "Aye", "sdp interlude", "SIRENS"])
        let unknown = video(
            createdAt: baseDate.addingTimeInterval(75),
            segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
        )
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Aye (feat. Travis Scott)"), start: 0, end: 30, status: .identified)]
                ),
                unknown,
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("SIRENS"), start: 0, end: 30, status: .identified)]
                )
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let inferred = classified.videos[1].segments[0]

        XCTAssertEqual(inferred.status, .possible)
        XCTAssertEqual(inferred.evidence.boundedCandidateOptions.map(\.song.title), ["Aye", "sdp interlude", "SIRENS"])
    }

    func testTemporalBoundsIgnoreUnresolvedNeighboringAnchors() {
        let selectedSetlist = setlist(titles: ["Song 1", "Song 2", "Song 3", "Song 4"])
        let unknown = video(
            createdAt: baseDate.addingTimeInterval(85),
            segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
        )
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [segment(song: song("Song 3"), start: 0, end: 30, status: .identified)]
                ),
                video(
                    createdAt: baseDate.addingTimeInterval(40),
                    segments: [segment(song: song("Definitely Not A Setlist Song"), start: 0, end: 30, status: .identified)]
                ),
                unknown,
                video(
                    createdAt: baseDate.addingTimeInterval(120),
                    segments: [segment(song: song("Song 4"), start: 0, end: 30, status: .identified)]
                )
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)
        let inferred = classified.videos[2].segments[0]

        XCTAssertEqual(inferred.status, .possible)
        XCTAssertEqual(inferred.evidence.boundedCandidateOptions.map(\.song.title), ["Song 3", "Song 4"])
    }

    func testUnknownVideoWithoutAnyAnchorStaysUnknown() {
        let selectedSetlist = setlist(titles: (1...5).map { "Song \($0)" })
        let record = AnalysisRecord(
            videos: [
                video(
                    createdAt: baseDate,
                    segments: [SongSegment(startTime: 0, endTime: 10, status: .unknown, primaryCandidate: nil)]
                )
            ],
            selectedSetlist: selectedSetlist
        )

        let classified = classifier.classify(record: record)

        XCTAssertEqual(classified.videos.first?.segments.first?.status, .unknown)
        XCTAssertNil(classified.videos.first?.segments.first?.primaryCandidate)
        XCTAssertEqual(classified.videos.first?.segments.first?.evidence.boundedCandidateOptions, [])
    }

    private func video(createdAt: Date, segments: [SongSegment]) -> ConcertVideo {
        ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/video.mov"),
            fileName: "video.mov",
            createdAt: createdAt,
            duration: 60,
            location: nil,
            segments: segments
        )
    }

    private func photo(createdAt: Date) -> ConcertPhoto {
        ConcertPhoto(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
            fileName: "photo.jpg",
            createdAt: createdAt,
            location: nil
        )
    }

    private func segment(song: SongIdentity, start: TimeInterval, end: TimeInterval, status: SegmentStatus) -> SongSegment {
        SongSegment(
            startTime: start,
            endTime: end,
            status: status,
            primaryCandidate: SongCandidate(
                song: song,
                setlistOccurrenceID: nil,
                evidenceScore: 1,
                confidenceLabel: .strong,
                reasons: []
            ),
            evidence: RecognitionEvidence(shazamWindowCount: 3, shazamMatchedDuration: end - start, classificationSource: .shazamKit)
        )
    }

    private func song(_ title: String) -> SongIdentity {
        SongIdentity(id: title.lowercased().replacingOccurrences(of: " ", with: "-"), title: title, artist: "Artist")
    }

    private func setlist(titles: [String]) -> ConcertSetlist {
        ConcertSetlist(
            id: "setlist-1",
            artistName: "Artist",
            venueName: "Venue",
            eventDate: baseDate,
            occurrences: titles.enumerated().map { offset, title in
                SetlistOccurrence(
                    id: "occurrence-\(offset + 1)",
                    setlistID: "setlist-1",
                    setNumber: 1,
                    songIndex: offset + 1,
                    overallIndex: offset + 1,
                    title: title,
                    normalizedTitle: TextNormalizer.normalizeSongTitle(title),
                    artist: "Artist"
                )
            },
            attributionURL: nil,
            versionID: "test"
        )
    }
}
