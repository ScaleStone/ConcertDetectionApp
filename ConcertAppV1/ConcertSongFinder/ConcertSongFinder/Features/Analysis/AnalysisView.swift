import ConcertSongFinderCore
import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var holder = AnalysisViewModelHolder()
    let record: AnalysisRecord
    let onComplete: (AnalysisRecord) -> Void
    let onCancel: (AnalysisRecord) -> Void

    var body: some View {
        Group {
            if let viewModel = holder.viewModel {
                content(viewModel)
            } else {
                ProgressView()
            }
        }
        .task {
            await startAnalysisIfNeeded()
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }

    private func startAnalysisIfNeeded() async {
        // The analysis runs in a task owned by the view model, so it is NOT
        // cancelled when this view disappears (e.g. the user switches tabs).
        // Re-entering this view awaits the same task instead of restarting.
        let viewModel: AnalysisViewModel
        if let existing = holder.viewModel {
            viewModel = existing
        } else {
            AppLog.analysis.info("Analysis task started for record \(record.id.uuidString, privacy: .public)")
            viewModel = AnalysisViewModel(record: record, environment: environment)
            holder.viewModel = viewModel
        }

        let completed = await viewModel.startAnalysis().value
        AppLog.analysis.info("Analysis task returned stage=\(completed.currentStage.rawValue, privacy: .public) videoStatuses=\(completed.videos.map { $0.analysisStatus.rawValue }.joined(separator: ","), privacy: .public) segmentCounts=\(completed.videos.map { String($0.segments.count) }.joined(separator: ","), privacy: .public)")

        if completed.currentStage == .canceled {
            onCancel(completed)
        } else {
            onComplete(completed)
        }
    }

    private func content(_ viewModel: AnalysisViewModel) -> some View {
        CSFScreen {
            CSFCard(padding: 18) {
                CSFHeroLead(
                    icon: icon(for: viewModel.stage),
                    title: stageTitle(viewModel.stage),
                    subtitle: "Extracting temporary audio, fingerprinting overlapping windows, separating concert clusters, and preserving uncertain ranges.",
                    tint: tint(for: viewModel.stage)
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(Int(viewModel.overallProgress * 100))%")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(CSFDesign.textPrimary.opacity(0.72))
                        Spacer()
                        CSFStatusChip(text: viewModel.stage.rawValue, icon: "bolt.horizontal", tint: tint(for: viewModel.stage))
                    }
                    ProgressView(value: viewModel.overallProgress)
                        .tint(CSFDesign.primary)
                }
            }

            CSFMetricGrid {
                CSFMetricTile(title: "Current Video", value: viewModel.currentVideoName.isEmpty ? "Preparing" : viewModel.currentVideoName, icon: "video.waveform", tint: CSFDesign.blue)
                CSFMetricTile(title: "Audio Range", value: viewModel.currentRangeDescription.isEmpty ? "Queued" : viewModel.currentRangeDescription, icon: "waveform.path", tint: CSFDesign.violet)
            }

            CSFCard {
                CSFSectionHeader(title: "Recognition Evidence", subtitle: "Confidence improves as Shazam windows, speech, setlist order, and lyric scores agree.")
                CSFMetricGrid {
                    CSFMetricTile(title: "Songs Found", value: "\(viewModel.songsFound)", icon: "music.note", tint: CSFDesign.primary)
                    CSFMetricTile(title: "Concerts", value: "Auto", icon: "rectangle.3.group", tint: CSFDesign.violet)
                    CSFMetricTile(title: "Privacy", value: "On Device", icon: "lock.shield", tint: CSFDesign.pink)
                }
            }

            if let error = viewModel.errorMessage {
                CSFCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.amber)
                }
            }

            Button(role: .cancel) {
                viewModel.cancel()
            } label: {
                Label("Cancel Analysis", systemImage: "xmark.circle")
            }
            .buttonStyle(CSFSecondaryButtonStyle())
        }
    }

    private func stageTitle(_ stage: RecognitionStage) -> String {
        switch stage {
        case .idle: "Preparing the concert"
        case .extractingAudio: "Extracting clean audio windows"
        case .checkingShazam: "Listening with ShazamKit"
        case .checkingSetlist: "Comparing likely setlists"
        case .buildingTimeline: "Building the song timeline"
        case .transcribing: "Transcribing difficult sections"
        case .comparingLyrics: "Scoring lyric fallbacks"
        case .completed: "Analysis complete"
        case .canceled: "Analysis canceled"
        }
    }

    private func icon(for stage: RecognitionStage) -> String {
        switch stage {
        case .idle: "hourglass"
        case .extractingAudio: "waveform"
        case .checkingShazam: "shazam.logo"
        case .checkingSetlist: "music.note.list"
        case .buildingTimeline: "timeline.selection"
        case .transcribing: "text.bubble"
        case .comparingLyrics: "text.quote"
        case .completed: "checkmark.seal.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    private func tint(for stage: RecognitionStage) -> Color {
        switch stage {
        case .completed:
            CSFDesign.primary
        case .canceled:
            CSFDesign.pink
        case .checkingShazam, .buildingTimeline:
            CSFDesign.blue
        case .transcribing, .comparingLyrics:
            CSFDesign.amber
        default:
            CSFDesign.violet
        }
    }
}

private final class AnalysisViewModelHolder: ObservableObject {
    @Published var viewModel: AnalysisViewModel?
}
