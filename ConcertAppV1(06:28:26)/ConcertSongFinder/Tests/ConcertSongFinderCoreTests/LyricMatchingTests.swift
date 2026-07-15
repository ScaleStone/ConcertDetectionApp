import XCTest
@testable import ConcertSongFinderCore

final class LyricMatchingTests: XCTestCase {
    private let matcher = DefaultLyricMatchingService()

    func testIncorrectTranscriptWithSimilarPhoneticSounds() {
        let identity = song("Never Too Much")
        let transcripts = [
            TranscriptAlternative(text: "never do much", confidence: 0.4, startTime: 0, endTime: 10)
        ]
        let lyrics = [
            SongLyrics(song: identity, lyrics: "never too much never too much i just do not want to stop", languageCode: "en")
        ]
        let occurrence = occurrence("Never Too Much", overall: 0)
        let candidates = matcher.rankCandidates(
            transcripts: transcripts,
            lyrics: lyrics,
            occurrences: [occurrence],
            context: RecognitionContext(
                setlistPriorByOccurrenceID: [occurrence.id: 1],
                neighboringSupportByOccurrenceID: [occurrence.id: 1]
            )
        )
        XCTAssertEqual(candidates.first?.song.title, "Never Too Much")
        XCTAssertNotEqual(candidates.first?.confidenceLabel, .insufficient)
    }

    func testCommonWordsProducingFalseLyricMatchArePenalized() {
        let identity = song("Actual Song")
        let transcripts = [
            TranscriptAlternative(text: "yeah the and you", confidence: 0.3, startTime: 0, endTime: 10)
        ]
        let lyrics = [
            SongLyrics(song: identity, lyrics: "you and the night and the lights and yeah", languageCode: "en")
        ]
        let candidates = matcher.rankCandidates(
            transcripts: transcripts,
            lyrics: lyrics,
            occurrences: [occurrence("Actual Song", overall: 0)],
            context: RecognitionContext()
        )
        XCTAssertEqual(candidates.first?.confidenceLabel, .insufficient)
    }

    func testCandidateScoresWithTooSmallMarginStayBelowLikely() {
        let songA = song("Song A")
        let songB = song("Song B")
        let transcripts = [
            TranscriptAlternative(text: "burning lights tonight", confidence: 0.5, startTime: 0, endTime: 10)
        ]
        let candidates = matcher.rankCandidates(
            transcripts: transcripts,
            lyrics: [
                SongLyrics(song: songA, lyrics: "burning lights tonight we run", languageCode: "en"),
                SongLyrics(song: songB, lyrics: "burning lights tonight we hide", languageCode: "en")
            ],
            occurrences: [occurrence("Song A", overall: 0), occurrence("Song B", overall: 1)],
            context: RecognitionContext()
        )
        XCTAssertNotEqual(candidates.first?.confidenceLabel, .likely)
    }

    func testMissingLyricsReturnNoCandidates() {
        let candidates = matcher.rankCandidates(
            transcripts: [TranscriptAlternative(text: "never too much", confidence: 0.5, startTime: 0, endTime: 10)],
            lyrics: [SongLyrics(song: song("Song A"), lyrics: nil)],
            occurrences: [occurrence("Song A", overall: 0)],
            context: RecognitionContext()
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testRepeatSongFallbackKeepsSeparateOccurrences() {
        let identity = song("Song A")
        let first = occurrence("Song A", overall: 0)
        let second = occurrence("Song A", overall: 3)
        let candidates = matcher.rankCandidates(
            transcripts: [TranscriptAlternative(text: "bright fire", confidence: 0.5, startTime: 0, endTime: 10)],
            lyrics: [SongLyrics(song: identity, lyrics: "bright fire in the sky", languageCode: "en")],
            occurrences: [first, second],
            context: RecognitionContext(setlistPriorByOccurrenceID: [second.id: 1])
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertNotEqual(candidates[0].setlistOccurrenceID, candidates[1].setlistOccurrenceID)
    }
}
