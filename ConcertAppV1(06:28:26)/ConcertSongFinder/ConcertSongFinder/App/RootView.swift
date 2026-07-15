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
                let record = AnalysisRecord(videos: mediaImport.videos, photos: mediaImport.photos)
                AppLog.importLog.info("RootView created upload analysis record=\(record.id.uuidString, privacy: .public) videos=\(mediaImport.videos.count, privacy: .public) photos=\(mediaImport.photos.count, privacy: .public)")
                uploadRoute = .setup(record)
            }
        case .setup(let record):
            ConcertSetupView(record: record) { updatedRecord in
                AppLog.concertLibrary.info("RootView moving upload record to concert assignment record=\(updatedRecord.id.uuidString, privacy: .public) hasSetlist=\((updatedRecord.selectedSetlist != nil), privacy: .public)")
                uploadRoute = .assign(updatedRecord)
            } onCancel: {
                AppLog.importLog.info("RootView upload setup cancelled record=\(record.id.uuidString, privacy: .public)")
                uploadRoute = .upload
            }
        case .assign(let record):
            ConcertAssignmentView(record: record) { combinedRecord in
                AppLog.concertLibrary.info("RootView starting analysis for assigned concert record=\(combinedRecord.id.uuidString, privacy: .public) videos=\(combinedRecord.videos.count, privacy: .public) photos=\(combinedRecord.photos.count, privacy: .public)")
                uploadRoute = .analysis(combinedRecord)
            } onCancel: {
                AppLog.concertLibrary.info("RootView concert assignment cancelled record=\(record.id.uuidString, privacy: .public)")
                uploadRoute = .upload
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
            let existingConcerts = try environment.concertLibraryStore.loadConcerts()
            let existing = existingConcerts.first { $0.id == record.id }
                ?? existingConcerts.first { $0.matches(analysisRecord: record) }
            let concert = existing?.merged(with: record) ?? ConcertRecord.newConcert(from: record)
            try environment.concertLibraryStore.upsertConcert(concert)
            AppLog.concertLibrary.info("RootView persisted completed concert=\(concert.id.uuidString, privacy: .public) record=\(record.id.uuidString, privacy: .public) videos=\(concert.videos.count, privacy: .public) photos=\(concert.photos.count, privacy: .public) stage=\(concert.currentStage.rawValue, privacy: .public)")
        } catch {
            AppLog.concertLibrary.error("RootView failed to persist completed concert record=\(record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum UploadRoute {
    case upload
    case setup(AnalysisRecord)
    case assign(AnalysisRecord)
    case analysis(AnalysisRecord)
    case results(AnalysisRecord)
}
