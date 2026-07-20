import XCTest
@testable import ConcertSongFinderCore

final class ComparableTitleTests: XCTestCase {
    func testStripsFeaturedArtistParenthetical() {
        XCTAssertEqual(
            TextNormalizer.comparableSongTitle("Dramatic Girl (feat. Che Ecru)"),
            TextNormalizer.comparableSongTitle("Dramatic Girl")
        )
    }

    func testStripsFeaturedArtistWithoutParenthetical() {
        XCTAssertEqual(
            TextNormalizer.comparableSongTitle("range brothers feat. Kendrick Lamar"),
            TextNormalizer.comparableSongTitle("Range Brothers")
        )
    }

    func testStripsBracketedQualifiers() {
        XCTAssertEqual(
            TextNormalizer.comparableSongTitle("HONEST [Live Version]"),
            TextNormalizer.comparableSongTitle("HONEST")
        )
    }

    func testDifferentSongsRemainDifferent() {
        XCTAssertNotEqual(
            TextNormalizer.comparableSongTitle("family ties"),
            TextNormalizer.comparableSongTitle("lost souls")
        )
    }

    func testPlainTitlesUnaffected() {
        XCTAssertEqual(TextNormalizer.comparableSongTitle("ORANGE SODA"), "orange soda")
    }
}
