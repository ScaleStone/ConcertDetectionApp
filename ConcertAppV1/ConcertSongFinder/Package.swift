// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ConcertSongFinder",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ConcertSongFinderCore",
            targets: ["ConcertSongFinderCore"]
        )
    ],
    targets: [
        .target(
            name: "ConcertSongFinderCore",
            path: "Sources/ConcertSongFinderCore"
        ),
        .testTarget(
            name: "ConcertSongFinderCoreTests",
            dependencies: ["ConcertSongFinderCore"],
            path: "Tests/ConcertSongFinderCoreTests"
        )
    ]
)
