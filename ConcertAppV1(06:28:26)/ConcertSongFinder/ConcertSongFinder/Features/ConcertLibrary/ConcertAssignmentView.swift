import ConcertSongFinderCore
import SwiftUI

struct ConcertAssignmentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var concerts: [ConcertRecord] = []
    @State private var status = "Checking concert library..."
    @State private var errorMessage: String?
    @State private var didAutoAssign = false

    let record: AnalysisRecord
    let onAnalyze: (AnalysisRecord) -> Void
    let onCancel: () -> Void

    var body: some View {
        List {
            Section("Upload") {
                LabeledContent("Videos", value: "\(record.videos.count)")
                LabeledContent("Photos", value: "\(record.photos.count)")
                LabeledContent("Detected Artist", value: detectedArtist ?? "Missing")
                if let date = detectedDate {
                    LabeledContent("Detected Date", value: Formatting.dateOnly.string(from: date))
                } else {
                    LabeledContent("Detected Date", value: "Missing")
                }
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Choose Concert") {
                ForEach(concerts) { concert in
                    Button {
                        assign(to: concert)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(concert.displayTitle)
                                .font(.headline)
                            Text(concert.displaySubtitle.isEmpty ? "\(concert.videos.count) videos • \(concert.photos.count) photos" : concert.displaySubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(concert.videos.count) videos • \(concert.photos.count) photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    createNewConcert()
                } label: {
                    Label("Create New Concert", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Assign Concert")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
        }
        .task {
            loadAndAutoAssignIfPossible()
        }
    }

    private var detectedArtist: String? {
        record.selectedSetlist?.artistName ?? record.selectedConcert?.artistName
    }

    private var detectedDate: Date? {
        record.selectedSetlist?.eventDate
            ?? record.selectedConcert?.eventDate
            ?? record.videos.compactMap(\.createdAt).min()
            ?? record.photos.compactMap(\.createdAt).min()
    }

    private func loadAndAutoAssignIfPossible() {
        guard !didAutoAssign else { return }
        didAutoAssign = true

        do {
            concerts = try environment.concertLibraryStore.loadConcerts()
                .sorted { $0.updatedAt > $1.updatedAt }
            AppLog.concertLibrary.info("Concert assignment loaded library count=\(concerts.count, privacy: .public) uploadRecord=\(record.id.uuidString, privacy: .public) detectedArtist=\(detectedArtist ?? "nil", privacy: .public) detectedDate=\(detectedDate?.ISO8601Format() ?? "nil", privacy: .public)")

            let matches = concerts.filter { $0.matches(analysisRecord: record) }
            if matches.count == 1, let match = matches.first {
                AppLog.concertLibrary.info("Concert assignment auto-matched existing concert=\(match.id.uuidString, privacy: .public) uploadRecord=\(record.id.uuidString, privacy: .public)")
                assign(to: match)
            } else if matches.count > 1 {
                status = "Multiple concerts matched. Choose the correct one."
                errorMessage = "More than one concert has the same artist and date."
                AppLog.concertLibrary.warning("Concert assignment found ambiguous matches count=\(matches.count, privacy: .public) uploadRecord=\(record.id.uuidString, privacy: .public)")
            } else if detectedArtist == nil || detectedDate == nil {
                status = "Choose a concert manually."
                errorMessage = "The upload could not be confidently matched from artist and date."
                AppLog.concertLibrary.warning("Concert assignment needs manual choice because detection is incomplete uploadRecord=\(record.id.uuidString, privacy: .public)")
            } else {
                status = "No existing concert matched before analysis. If Shazam finds a known setlist, this upload will be merged after analysis."
                AppLog.concertLibrary.info("Concert assignment found no pre-analysis match; post-analysis persistence can still merge by detected setlist artist/date uploadRecord=\(record.id.uuidString, privacy: .public) detectedArtist=\(detectedArtist ?? "nil", privacy: .public) detectedDate=\(detectedDate?.ISO8601Format() ?? "nil", privacy: .public)")
            }
        } catch {
            errorMessage = "Could not load My Concerts."
            status = "Library load failed."
            AppLog.concertLibrary.error("Concert assignment failed to load library uploadRecord=\(record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func assign(to concert: ConcertRecord) {
        let importBundle = ConcertMediaImport(videos: record.videos, photos: record.photos)
        var combined = concert.analysisRecord(appending: importBundle)
        combined.selectedConcert = concert.selectedConcert ?? record.selectedConcert
        combined.selectedSetlist = concert.selectedSetlist ?? record.selectedSetlist
        combined.currentStage = .idle
        AppLog.concertLibrary.info("Concert assignment merged upload into concert=\(concert.id.uuidString, privacy: .public) combinedVideos=\(combined.videos.count, privacy: .public) combinedPhotos=\(combined.photos.count, privacy: .public)")
        onAnalyze(combined)
    }

    private func createNewConcert() {
        AppLog.concertLibrary.info("Concert assignment creating new concert from uploadRecord=\(record.id.uuidString, privacy: .public) videos=\(record.videos.count, privacy: .public) photos=\(record.photos.count, privacy: .public)")
        onAnalyze(record)
    }
}
