import ConcertSongFinderCore
import SwiftUI

struct AnalysisDashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var records: [AnalysisRecord] = []
    @State private var errorMessage: String?

    private var latestRecord: AnalysisRecord? {
        records.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    var body: some View {
        CSFScreen {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analyzing")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                Text(latestRecord == nil ? "Import videos to start recognition" : "Latest concert recognition status")
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }

            if let record = latestRecord {
                activeAnalysisCard(record)
                recognitionWindows(record)
                pipeline(record)
            } else {
                CSFCard(padding: 22) {
                    CSFHeroLead(
                        icon: "waveform.badge.magnifyingglass",
                        title: "No analysis running",
                        subtitle: "Upload concert videos to extract audio, match Shazam windows, transcribe speech, score lyrics, and align setlists.",
                        tint: CSFDesign.violet
                    )
                }
            }

            if let errorMessage {
                CSFCard {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(CSFDesign.amber)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { loadRecords() }
        .refreshable { loadRecords() }
    }

    private func activeAnalysisCard(_ record: AnalysisRecord) -> some View {
        CSFCard(padding: 14) {
            StagePoster()
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.selectedSetlist?.artistName ?? record.selectedConcert?.artistName ?? record.fallbackTitle ?? "Concert")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(CSFDesign.textPrimary)
                        Text(record.selectedSetlist?.venueName ?? record.selectedConcert?.venueName ?? "Imported media")
                            .font(.subheadline)
                            .foregroundStyle(CSFDesign.textMuted)
                    }
                    .padding(14)
                }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress(for: record.currentStage))
                    .tint(CSFDesign.primary)
                Text("\(Int(progress(for: record.currentStage) * 100))% • \(songsFound(in: record)) tracks found • \(unknownCount(in: record)) unknown segments")
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }
        }
    }

    private func recognitionWindows(_ record: AnalysisRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CSFSectionHeader(title: "Recognition windows")
            HStack(spacing: 0) {
                ForEach(windowSegments(record), id: \.id) { segment in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color(for: segment.status))
                        .frame(minWidth: 24)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                legend("Identified", color: CSFDesign.primary)
                legend("Needs review", color: CSFDesign.amber)
                legend("Unknown", color: CSFDesign.textMuted)
            }
        }
    }

    private func pipeline(_ record: AnalysisRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CSFSectionHeader(title: "Pipeline")
            CSFCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(RecognitionStage.allCases.enumerated()), id: \.element.rawValue) { index, stage in
                        PipelineRow(stage: stage, activeStage: record.currentStage)
                        if index < RecognitionStage.allCases.count - 1 {
                            Divider().overlay(CSFDesign.line)
                        }
                    }
                }
            }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(CSFDesign.textMuted)
        }
    }

    private func loadRecords() {
        do {
            records = try environment.historyStore.loadRecords()
            errorMessage = nil
        } catch {
            errorMessage = "Could not load analysis history."
        }
    }

    private func windowSegments(_ record: AnalysisRecord) -> [SongSegment] {
        let segments = record.videos.flatMap(\.segments)
        if segments.isEmpty {
            return [
                SongSegment(startTime: 0, endTime: 1, status: .identified, primaryCandidate: nil),
                SongSegment(startTime: 1, endTime: 2, status: .likely, primaryCandidate: nil),
                SongSegment(startTime: 2, endTime: 3, status: .unknown, primaryCandidate: nil),
                SongSegment(startTime: 3, endTime: 4, status: .possible, primaryCandidate: nil)
            ]
        }
        return Array(segments.prefix(12))
    }

    private func color(for status: SegmentStatus) -> Color {
        switch status {
        case .identified, .userConfirmed:
            CSFDesign.primary
        case .likely:
            CSFDesign.violet
        case .possible, .transition, .speech:
            CSFDesign.amber
        case .unknown:
            CSFDesign.textMuted
        }
    }

    private func progress(for stage: RecognitionStage) -> Double {
        switch stage {
        case .idle: 0.08
        case .extractingAudio: 0.2
        case .checkingShazam: 0.4
        case .buildingTimeline: 0.58
        case .checkingSetlist: 0.68
        case .transcribing: 0.78
        case .comparingLyrics: 0.86
        case .completed: 1
        case .canceled: 0.5
        }
    }

    private func songsFound(in record: AnalysisRecord) -> Int {
        Set(record.videos.flatMap(\.segments).compactMap { $0.primaryCandidate?.song.id }).count
    }

    private func unknownCount(in record: AnalysisRecord) -> Int {
        record.videos.flatMap(\.segments).filter { $0.status == .unknown }.count
    }
}

private struct PipelineRow: View {
    let stage: RecognitionStage
    let activeStage: RecognitionStage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(statusColor)
            Text(stage.rawValue)
                .font(.subheadline)
                .foregroundStyle(CSFDesign.textPrimary)
            Spacer()
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(16)
    }

    private var statusText: String {
        if stage == activeStage { return activeStage == .completed ? "Done" : "Running" }
        return order(stage) < order(activeStage) ? "Done" : "Pending"
    }

    private var statusColor: Color {
        switch statusText {
        case "Done": return CSFDesign.primary
        case "Running": return CSFDesign.amber
        default: return CSFDesign.textMuted
        }
    }

    private var icon: String {
        switch stage {
        case .idle: "hourglass"
        case .extractingAudio: "waveform"
        case .checkingShazam: "shazam.logo"
        case .buildingTimeline: "timeline.selection"
        case .checkingSetlist: "music.note.list"
        case .transcribing: "text.bubble"
        case .comparingLyrics: "text.quote"
        case .completed: "checkmark.circle"
        case .canceled: "xmark.circle"
        }
    }

    private func order(_ stage: RecognitionStage) -> Int {
        RecognitionStage.allCases.firstIndex(of: stage) ?? 0
    }
}
