import Foundation
import os

private enum ClusteringLog {
    static let clustering = Logger(subsystem: "ConcertSongFinderCore", category: "clustering")
}

/// A group of media items that belong to the same concert, determined
/// primarily by capture timestamps.
public struct ConcertClusterAssignment: Identifiable, Codable, Hashable {
    public let id: UUID
    public var videoIDs: [UUID]
    public var photoIDs: [UUID]
    /// Earliest capture timestamp in the cluster; nil for the undated cluster.
    public var clusterDate: Date?
    /// True when this cluster holds media with no recoverable timestamp.
    public var isUndated: Bool
    public var selectedConcert: ConcertCandidate?
    public var selectedSetlist: ConcertSetlist?
    /// Label used when no concert could be identified for the cluster.
    public var fallbackLabel: String

    public init(
        id: UUID = UUID(),
        videoIDs: [UUID] = [],
        photoIDs: [UUID] = [],
        clusterDate: Date? = nil,
        isUndated: Bool = false,
        selectedConcert: ConcertCandidate? = nil,
        selectedSetlist: ConcertSetlist? = nil,
        fallbackLabel: String = ""
    ) {
        self.id = id
        self.videoIDs = videoIDs
        self.photoIDs = photoIDs
        self.clusterDate = clusterDate
        self.isUndated = isUndated
        self.selectedConcert = selectedConcert
        self.selectedSetlist = selectedSetlist
        self.fallbackLabel = fallbackLabel
    }

    public var displayTitle: String {
        if let artist = selectedSetlist?.artistName ?? selectedConcert?.artistName {
            return artist
        }
        return fallbackLabel.isEmpty ? "Concert" : fallbackLabel
    }
}

/// Groups imported media into concert clusters by capture timestamp.
///
/// The gap threshold is the sole split signal: consecutive items separated by
/// more than the threshold start a new cluster. This intentionally keeps
/// late-night shows that cross midnight in one cluster, and keeps openers and
/// headliners (different artists, same evening) together. Media without any
/// recoverable timestamp goes to a separate undated cluster, never guessed
/// into a dated one.
public enum ConcertClusterer {
    public static let defaultGapThreshold: TimeInterval = 6 * 60 * 60

    public static func cluster(
        videos: [ConcertVideo],
        photos: [ConcertPhoto],
        gapThreshold: TimeInterval = defaultGapThreshold
    ) -> [ConcertClusterAssignment] {
        struct DatedItem {
            let date: Date
            let videoID: UUID?
            let photoID: UUID?
        }

        var datedItems: [DatedItem] = []
        var undatedVideoIDs: [UUID] = []
        var undatedPhotoIDs: [UUID] = []

        for video in videos {
            if let createdAt = video.createdAt {
                datedItems.append(DatedItem(date: createdAt, videoID: video.id, photoID: nil))
            } else {
                undatedVideoIDs.append(video.id)
            }
        }
        for photo in photos {
            if let createdAt = photo.createdAt {
                datedItems.append(DatedItem(date: createdAt, videoID: nil, photoID: photo.id))
            } else {
                undatedPhotoIDs.append(photo.id)
            }
        }

        datedItems.sort { $0.date < $1.date }

        var clusters: [ConcertClusterAssignment] = []
        var currentVideoIDs: [UUID] = []
        var currentPhotoIDs: [UUID] = []
        var currentStart: Date?
        var previousDate: Date?

        func closeCurrentCluster() {
            guard !currentVideoIDs.isEmpty || !currentPhotoIDs.isEmpty else { return }
            clusters.append(
                ConcertClusterAssignment(
                    videoIDs: currentVideoIDs,
                    photoIDs: currentPhotoIDs,
                    clusterDate: currentStart,
                    isUndated: false
                )
            )
            currentVideoIDs = []
            currentPhotoIDs = []
            currentStart = nil
        }

        for item in datedItems {
            if let previousDate, item.date.timeIntervalSince(previousDate) > gapThreshold {
                closeCurrentCluster()
            }
            if currentStart == nil {
                currentStart = item.date
            }
            if let videoID = item.videoID {
                currentVideoIDs.append(videoID)
            }
            if let photoID = item.photoID {
                currentPhotoIDs.append(photoID)
            }
            previousDate = item.date
        }
        closeCurrentCluster()

        if !undatedVideoIDs.isEmpty || !undatedPhotoIDs.isEmpty {
            clusters.append(
                ConcertClusterAssignment(
                    videoIDs: undatedVideoIDs,
                    photoIDs: undatedPhotoIDs,
                    clusterDate: nil,
                    isUndated: true,
                    fallbackLabel: "Undated media"
                )
            )
        }

        ClusteringLog.clustering.info("Clustered media into \(clusters.count, privacy: .public) clusters videoCount=\(videos.count, privacy: .public) photoCount=\(photos.count, privacy: .public) gapThreshold=\(gapThreshold, privacy: .public) sizes=\(clusters.map { "\($0.videoIDs.count)v/\($0.photoIDs.count)p" }.joined(separator: ","), privacy: .public)")
        return clusters
    }

    /// Builds the fallback label for a cluster that could not be identified.
    public static func fallbackLabel(artist: String?, clusterDate: Date?, isUndated: Bool) -> String {
        if isUndated { return "Undated media" }
        let dateText = clusterDate.map { fallbackDateFormatter.string(from: $0) }
        switch (artist, dateText) {
        case let (.some(artist), .some(date)):
            return "\(artist) — \(date)"
        case let (.some(artist), .none):
            return artist
        case let (.none, .some(date)):
            return "Concert — \(date)"
        case (.none, .none):
            return "Concert"
        }
    }

    private static let fallbackDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
