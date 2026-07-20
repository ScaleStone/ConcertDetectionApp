import ConcertSongFinderCore
import SwiftUI

struct ConcertSetupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var holder = SetupViewModelHolder()
    let record: AnalysisRecord
    let onBeginAnalysis: (AnalysisRecord) -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            if let viewModel = holder.viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .task {
                        holder.viewModel = ConcertSetupViewModel(record: record, environment: environment)
                    }
            }
        }
        .navigationTitle("Concert Setup")
        .onChange(of: holder.viewModel != nil) { _, hasViewModel in
            guard hasViewModel, let viewModel = holder.viewModel else { return }
            AppLog.network.info("ConcertSetupView starting view-model owned automatic lookup record=\(record.id.uuidString, privacy: .public)")
            viewModel.startAutomaticLookupIfNeeded()
        }
        .onAppear {
            if let viewModel = holder.viewModel {
                AppLog.network.info("ConcertSetupView appeared with existing view model record=\(record.id.uuidString, privacy: .public)")
                viewModel.startAutomaticLookupIfNeeded()
            }
        }
        .onDisappear {
            AppLog.network.info("ConcertSetupView disappeared record=\(record.id.uuidString, privacy: .public) hasViewModel=\((holder.viewModel != nil), privacy: .public) isSearching=\(holder.viewModel?.isSearching ?? false, privacy: .public) status=\(holder.viewModel?.lookupStatus ?? "nil", privacy: .public)")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    AppLog.network.info("ConcertSetupView Cancel tapped record=\(record.id.uuidString, privacy: .public) isSearching=\(holder.viewModel?.isSearching ?? false, privacy: .public) status=\(holder.viewModel?.lookupStatus ?? "nil", privacy: .public)")
                    holder.viewModel?.cancelAutomaticLookup(reason: "cancel button tapped")
                    onCancel()
                } label: {
                    Text("Cancel")
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ viewModel: ConcertSetupViewModel) -> some View {
        Form {
            Section("Imported Media") {
                LabeledContent("Videos", value: "\(viewModel.record.videos.count)")
                LabeledContent("Photos", value: "\(viewModel.record.photos.count)")
                if let earliest = viewModel.earliestRecording {
                    LabeledContent("Earliest", value: Formatting.timestamp.string(from: earliest))
                } else {
                    LabeledContent("Earliest", value: "Missing")
                }
                if let latest = viewModel.latestRecording {
                    LabeledContent("Latest", value: Formatting.timestamp.string(from: latest))
                }
            }

            Section("Concert Details") {
                LabeledContent("Lookup", value: viewModel.lookupStatus)
                if let setlist = viewModel.selectedSetlist {
                    LabeledContent("Artist", value: setlist.artistName)
                    LabeledContent("Venue", value: setlist.venueName ?? "Unknown")
                    if let eventDate = setlist.eventDate {
                        LabeledContent("Date", value: Formatting.dateOnly.string(from: eventDate))
                    }
                    LabeledContent("Songs", value: "\(setlist.occurrences.count)")
                }
                Button {
                    Task { await viewModel.resolveConcertFromMetadata() }
                } label: {
                    Label("Recheck Timestamps", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isSearching)
            }

            if viewModel.isSearching {
                Section {
                    HStack {
                        ProgressView()
                        Text("Checking timestamps...")
                    }
                }
            }

            if !viewModel.concertCandidates.isEmpty {
                Section("Possible Matches") {
                    ForEach(viewModel.concertCandidates) { candidate in
                        Button {
                            Task { await viewModel.selectCandidate(candidate) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.artistName)
                                        .font(.headline)
                                    Text([candidate.venueName, candidate.city].compactMap { $0 }.joined(separator: " • "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let date = candidate.eventDate {
                                        Text(Formatting.dateOnly.string(from: date))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if viewModel.selectedCandidateID == candidate.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task {
                        AppLog.network.info("Begin Analysis tapped record=\(viewModel.record.id.uuidString, privacy: .public) isSearching=\(viewModel.isSearching, privacy: .public) status=\(viewModel.lookupStatus, privacy: .public) selectedSetlist=\((viewModel.selectedSetlist != nil), privacy: .public) candidateID=\(viewModel.selectedCandidateID ?? "nil", privacy: .public)")
                        viewModel.cancelAutomaticLookup(reason: "begin analysis tapped")
                        let updated = await viewModel.confirmedRecord()
                        AppLog.network.info("Begin Analysis confirmed record=\(updated.id.uuidString, privacy: .public) selectedSetlist=\((updated.selectedSetlist != nil), privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
                        onBeginAnalysis(updated)
                    }
                } label: {
                    Label("Begin Analysis", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private final class SetupViewModelHolder: ObservableObject {
    @Published var viewModel: ConcertSetupViewModel?
}
