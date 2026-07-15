import Foundation

public enum ConcertVideoOrdering {
    public static func sortedChronologically(_ videos: [ConcertVideo]) -> [ConcertVideo] {
        videos.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.originalSelectionIndex < $1.originalSelectionIndex
            }
        }
    }

    public static func removingDuplicates(_ videos: [ConcertVideo]) -> [ConcertVideo] {
        var seen: Set<String> = []
        var result: [ConcertVideo] = []
        for video in videos {
            let key = video.localIdentifier ?? video.localURL.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(video)
            }
        }
        return result
    }
}
