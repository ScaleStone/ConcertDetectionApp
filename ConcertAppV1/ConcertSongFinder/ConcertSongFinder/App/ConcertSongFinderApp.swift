import SwiftUI

@main
struct ConcertSongFinderApp: App {
    @StateObject private var environment = AppEnvironment.live()

    init() {
        // Clear share-sheet exports left over from previous sessions.
        MediaShareService.cleanUpSharedFiles()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
