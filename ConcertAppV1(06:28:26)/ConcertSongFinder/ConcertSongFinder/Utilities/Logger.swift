import Foundation
import os

enum AppLog {
    static let analysis = Logger(subsystem: "ConcertSongFinder", category: "analysis")
    static let importLog = Logger(subsystem: "ConcertSongFinder", category: "import")
    static let network = Logger(subsystem: "ConcertSongFinder", category: "network")
    static let mediaClassification = Logger(subsystem: "ConcertSongFinder", category: "media-classification")
    static let concertLibrary = Logger(subsystem: "ConcertSongFinder", category: "concert-library")
}
