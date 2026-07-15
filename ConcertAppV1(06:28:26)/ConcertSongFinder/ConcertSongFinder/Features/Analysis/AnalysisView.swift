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
        .navigationBarBackButtonHidden()
    }

    private func startAnalysisIfNeeded() async {
        guard !holder.hasStartedAnalysis else { return }
        holder.hasStartedAnalysis = true

        AppLog.analysis.info("Analysis task started for record \(record.id.uuidString, privacy: .public)")
        let viewModel = AnalysisViewModel(record: record, environment: environment)
        holder.viewModel = viewModel

        let completed = await viewModel.analyze()
        AppLog.analysis.info("Analysis task returned stage=\(completed.currentStage.rawValue, privacy: .public) videoStatuses=\(completed.videos.map { $0.analysisStatus.rawValue }.joined(separator: ","), privacy: .public) segmentCounts=\(completed.videos.map { String($0.segments.count) }.joined(separator: ","), privacy: .public)")

        if completed.currentStage == .canceled {
            onCancel(completed)
        } else {
            onComplete(completed)
        }
    }

    private func content(_ viewModel: AnalysisViewModel) -> some View {
        List {
            Section {
                ProgressView(value: viewModel.overallProgress)
                LabeledContent("Current video", value: viewModel.currentVideoName.isEmpty ? "Preparing" : viewModel.currentVideoName)
                LabeledContent("Audio range", value: viewModel.currentRangeDescription.isEmpty ? "Queued" : viewModel.currentRangeDescription)
                LabeledContent("Songs found", value: "\(viewModel.songsFound)")
                LabeledContent("Stage", value: viewModel.stage.rawValue)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(role: .cancel) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel Analysis", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private final class AnalysisViewModelHolder: ObservableObject {
    @Published var viewModel: AnalysisViewModel?
    var hasStartedAnalysis = false
}
