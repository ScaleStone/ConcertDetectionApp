import XCTest
@testable import ConcertSongFinderCore

final class SetlistAlignmentTests: XCTestCase {
    private let service = DefaultSetlistAlignmentService()

    func testSetlistWithRepeatedSongTitlesMapsLaterOccurrence() {
        let setlist = [
            occurrence("Song A", overall: 0),
            occurrence("Song B", overall: 1),
            occurrence("Song C", overall: 2),
            occurrence("Song A", overall: 3),
            occurrence("Song D", overall: 4)
        ]
        let observations = [
            observation("Song B", videoOrder: 0),
            observation("Song A", videoOrder: 2),
            observation("Song D", videoOrder: 3)
        ]
        let alignment = service.align(observations: observations, to: setlist)
        let songAObservation = observations[1]
        let mapped = alignment.mappings.first { $0.observationID == songAObservation.id }
        XCTAssertEqual(mapped?.occurrenceOverallIndex, 3)
    }

    func testRecognizedAnchorsSurroundingUnknownVideoShortlistMiddle() {
        let setlist = (0..<6).map { occurrence("Song \($0)", overall: $0) }
        let observations = [
            observation("Song 1", videoOrder: 0),
            observation("Song 4", videoOrder: 2)
        ]
        let alignment = service.align(observations: observations, to: setlist)
        let window = service.candidateWindow(forVideoOrder: 1, observations: observations, occurrences: setlist, alignment: alignment)
        XCTAssertEqual(window.occurrences.map(\.overallIndex), [1, 2, 3, 4])
    }

    func testOnlyPreviousAnchorShortlistsNextSongs() {
        let setlist = (0..<10).map { occurrence("Song \($0)", overall: $0) }
        let observations = [observation("Song 3", videoOrder: 0)]
        let alignment = service.align(observations: observations, to: setlist)
        let window = service.candidateWindow(forVideoOrder: 1, observations: observations, occurrences: setlist, alignment: alignment, radius: 3)
        XCTAssertEqual(window.occurrences.map(\.overallIndex), [3, 4, 5, 6])
    }

    func testOnlyLaterAnchorShortlistsPreviousSongs() {
        let setlist = (0..<10).map { occurrence("Song \($0)", overall: $0) }
        let observations = [observation("Song 6", videoOrder: 2)]
        let alignment = service.align(observations: observations, to: setlist)
        let window = service.candidateWindow(forVideoOrder: 1, observations: observations, occurrences: setlist, alignment: alignment, radius: 3)
        XCTAssertEqual(window.occurrences.map(\.overallIndex), [3, 4, 5, 6])
    }

    func testNoRecognizedAnchorsUsesWholeSetlistWithLowerConfidence() {
        let setlist = (0..<4).map { occurrence("Song \($0)", overall: $0) }
        let alignment = service.align(observations: [], to: setlist)
        let window = service.candidateWindow(forVideoOrder: 1, observations: [], occurrences: setlist, alignment: alignment)
        XCTAssertEqual(window.occurrences.count, 4)
        XCTAssertLessThan(window.confidenceModifier, 0)
    }

    func testTwoEquallyValidRepeatedSongOccurrencesRemainAmbiguous() {
        let setlist = [
            occurrence("Song A", overall: 0),
            occurrence("Song B", overall: 1),
            occurrence("Song A", overall: 2)
        ]
        let observations = [observation("Song A", videoOrder: 0)]
        let alignment = service.align(observations: observations, to: setlist)
        XCTAssertTrue(alignment.isAmbiguous)
        XCTAssertEqual(alignment.mappings.first?.ambiguousOccurrenceIDs.count, 1)
    }

    func testSetlistWithEncorePreservesOccurrenceOrder() {
        let setlist = [
            occurrence("Main Song", overall: 0, setNumber: 0, isEncore: false),
            occurrence("Encore Song", overall: 1, setNumber: 1, isEncore: true)
        ]
        XCTAssertFalse(setlist[0].isEncore)
        XCTAssertTrue(setlist[1].isEncore)
        XCTAssertLessThan(setlist[0].overallIndex, setlist[1].overallIndex)
    }

    func testUserCorrectionCausesRealignmentTowardCorrectOccurrence() {
        let setlist = [
            occurrence("Song A", overall: 0),
            occurrence("Song B", overall: 1),
            occurrence("Song A", overall: 2)
        ]
        let observations = [
            observation("Song B", videoOrder: 0, confirmed: true),
            observation("Song A", videoOrder: 1, confirmed: true)
        ]
        let alignment = service.align(observations: observations, to: setlist)
        XCTAssertEqual(alignment.mappings.last?.occurrenceOverallIndex, 2)
    }
}

func occurrence(
    _ title: String,
    overall: Int,
    setNumber: Int = 0,
    songIndex: Int? = nil,
    isEncore: Bool = false
) -> SetlistOccurrence {
    let index = songIndex ?? overall
    return SetlistOccurrence(
        id: "set-\(setNumber)-\(index)-\(overall)",
        setlistID: "set",
        setNumber: setNumber,
        songIndex: index,
        overallIndex: overall,
        title: title,
        normalizedTitle: TextNormalizer.normalizeSongTitle(title),
        artist: "Artist",
        setName: isEncore ? "Encore" : "Main",
        isEncore: isEncore,
        isTape: false,
        notes: nil
    )
}

func observation(_ title: String, videoOrder: Int, confirmed: Bool = false) -> SongObservation {
    SongObservation(
        videoID: UUID(),
        segmentID: UUID(),
        videoOrder: videoOrder,
        segmentStart: 0,
        segmentEnd: 30,
        song: song(title),
        confidenceLabel: confirmed ? .strong : .likely,
        isUserConfirmed: confirmed
    )
}
