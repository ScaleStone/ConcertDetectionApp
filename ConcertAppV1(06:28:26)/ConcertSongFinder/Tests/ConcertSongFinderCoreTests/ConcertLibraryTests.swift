import XCTest
@testable import ConcertSongFinderCore

final class ConcertLibraryTests: XCTestCase {
    func testConcertMatchesIncomingAnalysisByArtistAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "The Artist", date: date),
            selectedSetlist: setlist(artist: "The Artist", date: date),
            videos: [video(index: 0, createdAt: date)]
        )
        let incoming = AnalysisRecord(
            videos: [video(index: 1, createdAt: date.addingTimeInterval(60))],
            selectedConcert: candidate(artist: "the artist", date: date.addingTimeInterval(60))
        )

        XCTAssertTrue(concert.matches(analysisRecord: incoming))
    }

    func testConcertDoesNotMatchDifferentArtistOnSameDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist A", date: date),
            videos: [video(index: 0, createdAt: date)]
        )
        let incoming = AnalysisRecord(
            videos: [video(index: 1, createdAt: date)],
            selectedConcert: candidate(artist: "Artist B", date: date)
        )

        XCTAssertFalse(concert.matches(analysisRecord: incoming))
    }

    func testMergedConcertKeepsExistingAndIncomingMedia() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existingVideo = video(index: 0, createdAt: date)
        let incomingVideo = video(index: 1, createdAt: date.addingTimeInterval(90))
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist", date: date),
            videos: [existingVideo]
        )
        let incoming = AnalysisRecord(
            videos: [incomingVideo],
            selectedConcert: candidate(artist: "Artist", date: date)
        )

        let merged = concert.merged(with: incoming)

        XCTAssertEqual(merged.videos.map(\.id), [existingVideo.id, incomingVideo.id])
    }

    func testMergedConcertSkipsDuplicateVideoAssetWithNewGeneratedID() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existingVideo = video(index: 0, createdAt: date, localIdentifier: "asset-1")
        let duplicateVideo = video(index: 1, createdAt: date, localIdentifier: "asset-1")
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist", date: date),
            videos: [existingVideo]
        )
        let incoming = AnalysisRecord(
            videos: [duplicateVideo],
            selectedConcert: candidate(artist: "Artist", date: date)
        )

        let merged = concert.merged(with: incoming)

        XCTAssertEqual(merged.videos.map(\.id), [existingVideo.id])
    }

    func testMergedConcertSkipsDuplicateVideoByTimestampAndDurationWhenAssetIDIsMissing() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existingVideo = video(index: 0, createdAt: date, duration: 30, hasLocalIdentifier: false)
        let duplicateVideo = video(index: 1, createdAt: date, duration: 30, hasLocalIdentifier: false)
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist", date: date),
            videos: [existingVideo]
        )
        let incoming = AnalysisRecord(
            videos: [duplicateVideo],
            selectedConcert: candidate(artist: "Artist", date: date)
        )

        let merged = concert.merged(with: incoming)

        XCTAssertEqual(merged.videos.map(\.id), [existingVideo.id])
    }

    func testMergedConcertSkipsDuplicatePhotoAssetWithNewGeneratedID() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existingPhoto = photo(index: 0, createdAt: date, localIdentifier: "photo-asset-1")
        let duplicatePhoto = photo(index: 1, createdAt: date, localIdentifier: "photo-asset-1")
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist", date: date),
            photos: [existingPhoto]
        )
        let incoming = AnalysisRecord(
            videos: [],
            photos: [duplicatePhoto],
            selectedConcert: candidate(artist: "Artist", date: date)
        )

        let merged = concert.merged(with: incoming)

        XCTAssertEqual(merged.photos.map(\.id), [existingPhoto.id])
    }

    func testConcertLibraryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = JSONConcertLibraryStore(fileURL: url)
        let concert = ConcertRecord(
            selectedConcert: candidate(artist: "Artist", date: Date(timeIntervalSince1970: 1_700_000_000)),
            videos: [video(index: 0)]
        )

        try store.upsertConcert(concert)
        let loaded = try store.loadConcerts()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, concert.id)
        XCTAssertEqual(loaded.first?.videos.count, 1)
        try? FileManager.default.removeItem(at: url)
    }
}

private func candidate(artist: String, date: Date) -> ConcertCandidate {
    ConcertCandidate(
        id: UUID().uuidString,
        artistName: artist,
        venueName: "Venue",
        city: "City",
        eventDate: date,
        confidenceScore: 0.9,
        attributionURL: nil
    )
}

private func setlist(artist: String, date: Date) -> ConcertSetlist {
    ConcertSetlist(
        id: UUID().uuidString,
        artistName: artist,
        venueName: "Venue",
        eventDate: date,
        occurrences: [occurrence("Song", overall: 0)],
        attributionURL: nil,
        versionID: "v1"
    )
}

private func occurrence(_ title: String, overall: Int) -> SetlistOccurrence {
    SetlistOccurrence(
        id: "occurrence-\(overall)",
        setlistID: "setlist-1",
        setNumber: 1,
        songIndex: overall,
        overallIndex: overall,
        title: title,
        normalizedTitle: TextNormalizer.normalizeSongTitle(title),
        artist: "Artist"
    )
}

private func video(
    index: Int,
    createdAt: Date? = nil,
    duration: TimeInterval = 10,
    localIdentifier: String? = nil,
    hasLocalIdentifier: Bool = true
) -> ConcertVideo {
    ConcertVideo(
        localIdentifier: hasLocalIdentifier ? (localIdentifier ?? "video-\(index)") : nil,
        localURL: URL(fileURLWithPath: "/tmp/video-\(index).mov"),
        fileName: "video-\(index).mov",
        createdAt: createdAt,
        duration: duration,
        location: nil,
        originalSelectionIndex: index
    )
}

private func photo(index: Int, createdAt: Date? = nil, localIdentifier: String? = nil) -> ConcertPhoto {
    ConcertPhoto(
        localIdentifier: localIdentifier ?? "photo-\(index)",
        localURL: URL(fileURLWithPath: "/tmp/photo-\(index).jpg"),
        fileName: "photo-\(index).jpg",
        createdAt: createdAt,
        location: nil,
        originalSelectionIndex: index
    )
}
