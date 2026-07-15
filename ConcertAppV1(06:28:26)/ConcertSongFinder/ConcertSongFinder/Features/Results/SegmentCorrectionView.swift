import ConcertSongFinderCore
import SwiftUI

struct SegmentCorrectionView: View {
    let selection: SegmentCorrectionSelection
    let onApply: (SegmentCorrection) -> Void
    @State private var startTime: Double
    @State private var endTime: Double

    init(selection: SegmentCorrectionSelection, onApply: @escaping (SegmentCorrection) -> Void) {
        self.selection = selection
        self.onApply = onApply
        _startTime = State(initialValue: selection.segment.startTime)
        _endTime = State(initialValue: selection.segment.endTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Segment") {
                    LabeledContent("Range", value: "\(Formatting.duration(selection.segment.startTime))-\(Formatting.duration(selection.segment.endTime))")
                    LabeledContent("Status", value: selection.segment.status.rawValue.capitalized)
                    if let candidate = selection.segment.primaryCandidate {
                        LabeledContent("Current", value: "\(candidate.song.title) — \(candidate.song.artist)")
                    }
                }

                if let primary = selection.segment.primaryCandidate {
                    Section("Confirm") {
                        Button {
                            onApply(SegmentCorrection(videoID: selection.videoID, segmentID: selection.segment.id, action: .confirmCandidate(primary)))
                        } label: {
                            Label("Confirm \(primary.song.title)", systemImage: "checkmark.circle")
                        }
                    }
                }

                if !selection.segment.alternativeCandidates.isEmpty {
                    Section("Alternatives") {
                        ForEach(selection.segment.alternativeCandidates) { candidate in
                            Button {
                                onApply(SegmentCorrection(videoID: selection.videoID, segmentID: selection.segment.id, action: .confirmCandidate(candidate)))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(candidate.song.title)
                                    Text("\(candidate.song.artist) • \(candidate.confidenceLabel.rawValue.capitalized)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Boundary") {
                    Stepper("Start \(Formatting.duration(startTime))", value: $startTime, in: 0...max(endTime, 0), step: 1)
                    Stepper("End \(Formatting.duration(endTime))", value: $endTime, in: max(startTime, 0)...max(selection.segment.endTime + 30, startTime + 1), step: 1)
                    Button {
                        onApply(SegmentCorrection(videoID: selection.videoID, segmentID: selection.segment.id, action: .adjustBoundary(start: startTime, end: endTime)))
                    } label: {
                        Label("Save Boundary", systemImage: "arrow.left.and.right")
                    }
                }

                Section("Mark As") {
                    Button {
                        onApply(SegmentCorrection(videoID: selection.videoID, segmentID: selection.segment.id, action: .markSpeech))
                    } label: {
                        Label("Speech or Interlude", systemImage: "quote.bubble")
                    }
                    Button {
                        onApply(SegmentCorrection(videoID: selection.videoID, segmentID: selection.segment.id, action: .markUnknown))
                    } label: {
                        Label("Unknown", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Correct Segment")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
