import ConcertSongFinderCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var uploadRoute: UploadRoute = .upload

    var body: some View {
        TabView {
            NavigationStack {
                uploadFlow
            }
            .tabItem {
                Label("Upload", systemImage: "square.and.arrow.up")
            }

            NavigationStack {
                MyConcertsView()
            }
            .tabItem {
                Label("My Concerts", systemImage: "music.mic")
            }
        }
    }

    @ViewBuilder
    private var uploadFlow: some View {
        switch uploadRoute {
        case .upload:
            HomeView { mediaImport in
                // Analysis starts immediately after import; concert
                // assignment is fully automatic (identification first,
                // timestamp fallback otherwise) at persistence time.
                let record = AnalysisRecord(videos: mediaImport.videos, photos: mediaImport.photos)
                AppLog.importLog.info("RootView starting automatic analysis record=\(record.id.uuidString, privacy: .public) videos=\(mediaImport.videos.count, privacy: .public) photos=\(mediaImport.photos.count, privacy: .public)")
                uploadRoute = .analysis(record)
            }
        case .analysis(let record):
            AnalysisView(record: record) { completedRecord in
                persistCompletedConcert(completedRecord)
                uploadRoute = .results(completedRecord)
            } onCancel: { partialRecord in
                persistCompletedConcert(partialRecord)
                uploadRoute = .results(partialRecord)
            }
        case .results(let record):
            ResultsView(record: record) {
                AppLog.concertLibrary.info("RootView leaving results for record=\(record.id.uuidString, privacy: .public)")
                uploadRoute = .upload
            }
        }
    }

    private func persistCompletedConcert(_ record: AnalysisRecord) {
        do {
            // Fully automatic assignment: each timestamp cluster merges into
            // an existing concert (by identity, artist+day, or same-evening
            // timestamps) or becomes a new concert.
            let existingConcerts = try environment.concertLibraryStore.loadConcerts()
            for subRecord in record.perClusterAnalysisRecords() {
                let existing = ConcertRecord.findMatch(for: subRecord, in: existingConcerts)
                let concert = existing?.merged(with: subRecord) ?? ConcertRecord.newConcert(from: subRecord)
                try environment.concertLibraryStore.upsertConcert(concert)
                AppLog.concertLibrary.info("RootView persisted concert=\(concert.id.uuidString, privacy: .public) record=\(record.id.uuidString, privacy: .public) title=\(concert.displayTitle, privacy: .public) videos=\(concert.videos.count, privacy: .public) photos=\(concert.photos.count, privacy: .public)")
            }
        } catch {
            AppLog.concertLibrary.error("RootView failed to persist completed concert record=\(record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum UploadRoute {
    case upload
    case analysis(AnalysisRecord)
    case results(AnalysisRecord)
}
