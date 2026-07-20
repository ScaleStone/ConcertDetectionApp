import XCTest
@testable import ConcertSongFinderCore

final class ClusteringTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeVideo(hoursFromBase: Double?, name: String = "video") -> ConcertVideo {
        ConcertVideo(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString).mov"),
            fileName: "\(name).mov",
            createdAt: hoursFromBase.map { base.addingTimeInterval($0 * 3600) },
            duration: 60,
            location: nil
        )
    }

    private func makePhoto(hoursFromBase: Double?, name: String = "photo") -> ConcertPhoto {
        ConcertPhoto(
            localIdentifier: nil,
            localURL: URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString).jpg"),
            fileName: "\(name).jpg",
            createdAt: hoursFromBase.map { base.addingTimeInterval($0 * 3600) },
            location: nil
        )
    }

    func testSameEveningMediaFormsOneCluster() {
        let videos = [makeVideo(hoursFromBase: 0), makeVideo(hoursFromBase: 1), makeVideo(hoursFromBase: 2.5)]
        let clusters = ConcertClusterer.cluster(videos: videos, photos: [])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].videoIDs.count, 3)
        XCTAssertFalse(clusters[0].isUndated)
    }

    func testGapBeyondThresholdSplitsClusters() {
        let videos = [
            makeVideo(hoursFromBase: 0),
            makeVideo(hoursFromBase: 1),
            makeVideo(hoursFromBase: 26), // next day, > 6h gap
            makeVideo(hoursFromBase: 27)
        ]
        let clusters = ConcertClusterer.cluster(videos: videos, photos: [])
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].videoIDs.count, 2)
        XCTAssertEqual(clusters[1].videoIDs.count, 2)
        XCTAssertNotNil(clusters[0].clusterDate)
        XCTAssertNotNil(clusters[1].clusterDate)
        XCTAssertLessThan(clusters[0].clusterDate!, clusters[1].clusterDate!)
    }

    func testLateNightShowCrossingMidnightStaysTogether() {
        // 23:00 and 00:45 the next day: gap is 1h45m, well under threshold.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 23))!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 6, day: 25, hour: 0, minute: 45))!

        let videos = [
            ConcertVideo(localIdentifier: nil, localURL: URL(fileURLWithPath: "/tmp/a.mov"), fileName: "a.mov", createdAt: evening, duration: 60, location: nil),
            ConcertVideo(localIdentifier: nil, localURL: URL(fileURLWithPath: "/tmp/b.mov"), fileName: "b.mov", createdAt: afterMidnight, duration: 60, location: nil)
        ]
        let clusters = ConcertClusterer.cluster(videos: videos, photos: [])
        XCTAssertEqual(clusters.count, 1, "A show crossing midnight must not be split")
    }

    func testUndatedMediaGoesToSeparateCluster() {
        let videos = [makeVideo(hoursFromBase: 0), makeVideo(hoursFromBase: nil)]
        let photos = [makePhoto(hoursFromBase: nil)]
        let clusters = ConcertClusterer.cluster(videos: videos, photos: photos)
        XCTAssertEqual(clusters.count, 2)
        let undated = clusters.first { $0.isUndated }
        XCTAssertNotNil(undated)
        XCTAssertEqual(undated?.videoIDs.count, 1)
        XCTAssertEqual(undated?.photoIDs.count, 1)
        XCTAssertNil(undated?.clusterDate)
        XCTAssertEqual(undated?.fallbackLabel, "Undated media")
    }

    func testPhotosClusterWithNearbyVideos() {
        let videos = [makeVideo(hoursFromBase: 0), makeVideo(hoursFromBase: 26)]
        let photos = [makePhoto(hoursFromBase: 0.5), makePhoto(hoursFromBase: 26.5)]
        let clusters = ConcertClusterer.cluster(videos: videos, photos: photos)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].videoIDs.count, 1)
        XCTAssertEqual(clusters[0].photoIDs.count, 1)
        XCTAssertEqual(clusters[1].videoIDs.count, 1)
        XCTAssertEqual(clusters[1].photoIDs.count, 1)
    }

    func testFallbackLabels() {
        XCTAssertEqual(ConcertClusterer.fallbackLabel(artist: nil, clusterDate: nil, isUndated: true), "Undated media")
        XCTAssertEqual(ConcertClusterer.fallbackLabel(artist: "Don Toliver", clusterDate: nil, isUndated: false), "Don Toliver")
        let label = ConcertClusterer.fallbackLabel(artist: "Don Toliver", clusterDate: base, isUndated: false)
        XCTAssertTrue(label.hasPrefix("Don Toliver — "))
        let dateOnly = ConcertClusterer.fallbackLabel(artist: nil, clusterDate: base, isUndated: false)
        XCTAssertTrue(dateOnly.hasPrefix("Concert — "))
    }

    func testPerClusterAnalysisRecordsSplitsMediaByCluster() {
        let videoA = makeVideo(hoursFromBase: 0, name: "concertA")
        let videoB = makeVideo(hoursFromBase: 26, name: "concertB")
        let photoA = makePhoto(hoursFromBase: 0.5, name: "photoA")
        let record = AnalysisRecord(
            videos: [videoA, videoB],
            photos: [photoA],
            rawMatchesByVideoID: [
                videoA.id: [RawRecognitionMatch(windowStart: 0, windowEnd: 10, song: SongIdentity(id: "s1", title: "Song 1", artist: "Artist A"))],
                videoB.id: [RawRecognitionMatch(windowStart: 0, windowEnd: 10, song: SongIdentity(id: "s2", title: "Song 2", artist: "Artist B"))]
            ],
            clusters: [
                ConcertClusterAssignment(videoIDs: [videoA.id], photoIDs: [photoA.id], clusterDate: videoA.createdAt, fallbackLabel: "Artist A — date"),
                ConcertClusterAssignment(videoIDs: [videoB.id], photoIDs: [], clusterDate: videoB.createdAt, fallbackLabel: "Artist B — date")
            ]
        )

        let subRecords = record.perClusterAnalysisRecords()
        XCTAssertEqual(subRecords.count, 2)

        XCTAssertEqual(subRecords[0].videos.map(\.id), [videoA.id])
        XCTAssertEqual(subRecords[0].photos.map(\.id), [photoA.id])
        XCTAssertEqual(subRecords[0].rawMatchesByVideoID.keys.count, 1)
        XCTAssertNotNil(subRecords[0].rawMatchesByVideoID[videoA.id])
        XCTAssertEqual(subRecords[0].fallbackTitle, "Artist A — date")

        XCTAssertEqual(subRecords[1].videos.map(\.id), [videoB.id])
        XCTAssertTrue(subRecords[1].photos.isEmpty)
        XCTAssertEqual(subRecords[1].fallbackTitle, "Artist B — date")

        // Sub-record ids are the stable cluster ids so re-persisting merges
        // instead of duplicating.
        XCTAssertEqual(subRecords.map(\.id), record.clusters.map(\.id))
    }

    func testSingleClusterRecordKeepsRecordIdentity() {
        let video = makeVideo(hoursFromBase: 0)
        let cluster = ConcertClusterAssignment(videoIDs: [video.id], photoIDs: [], clusterDate: video.createdAt, fallbackLabel: "Solo — date")
        let record = AnalysisRecord(videos: [video], clusters: [cluster])

        let subRecords = record.perClusterAnalysisRecords()
        XCTAssertEqual(subRecords.count, 1)
        XCTAssertEqual(subRecords[0].id, record.id, "Single-cluster records must keep their own id for library matching")
        XCTAssertEqual(subRecords[0].fallbackTitle, "Solo — date")
    }

    func testRecordWithoutClustersReturnsSelf() {
        let video = makeVideo(hoursFromBase: 0)
        let record = AnalysisRecord(videos: [video])
        let subRecords = record.perClusterAnalysisRecords()
        XCTAssertEqual(subRecords.count, 1)
        XCTAssertEqual(subRecords[0].id, record.id)
    }

    func testClusterAssignmentRoundTripsThroughCodable() throws {
        let cluster = ConcertClusterAssignment(
            videoIDs: [UUID()],
            photoIDs: [UUID()],
            clusterDate: base,
            isUndated: false,
            fallbackLabel: "Artist — date"
        )
        let record = AnalysisRecord(videos: [], clusters: [cluster], fallbackTitle: "Artist — date")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AnalysisRecord.self, from: data)
        XCTAssertEqual(decoded.clusters, [cluster])
        XCTAssertEqual(decoded.fallbackTitle, "Artist — date")
    }

    func testLegacyRecordJSONWithoutClustersDecodes() throws {
        // Simulates a record persisted before clustering existed.
        let record = AnalysisRecord(videos: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "clusters")
        json.removeValue(forKey: "fallbackTitle")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AnalysisRecord.self, from: data)
        XCTAssertTrue(decoded.clusters.isEmpty)
        XCTAssertNil(decoded.fallbackTitle)
    }
}
