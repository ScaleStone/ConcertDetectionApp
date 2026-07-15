import AVFoundation
import ConcertSongFinderCore
import SwiftUI
import UIKit

struct ResultsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var holder = ResultsViewModelHolder()
    let record: AnalysisRecord
    let onDone: () -> Void

    var body: some View {
        Group {
            if let viewModel = holder.viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .task {
                        holder.viewModel = ResultsViewModel(record: record, environment: environment)
                    }
            }
        }
        .navigationTitle("Results")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: onDone)
            }
        }
    }

    @ViewBuilder
    private func content(_ viewModel: ResultsViewModel) -> some View {
        List {
            if let setlist = viewModel.record.selectedSetlist, let attribution = setlist.attributionURL {
                Section {
                    Link("Setlist data attribution", destination: attribution)
                        .font(.caption)
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            ForEach(viewModel.record.videos) { video in
                Section {
                    VideoResultCard(video: video) { segment in
                        viewModel.selectedCorrection = SegmentCorrectionSelection(videoID: video.id, segment: segment)
                    }
                }
            }

            if !viewModel.record.photos.isEmpty {
                Section("Photos") {
                    ForEach(viewModel.record.photos) { photo in
                        PhotoResultCard(photo: photo)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    viewModel.deleteHistory()
                    onDone()
                } label: {
                    Label("Delete Saved Analysis", systemImage: "trash")
                }
            }
        }
        .sheet(item: Binding(
            get: { viewModel.selectedCorrection },
            set: { viewModel.selectedCorrection = $0 }
        )) { selection in
            SegmentCorrectionView(selection: selection) { correction in
                viewModel.applyCorrection(correction)
                viewModel.selectedCorrection = nil
            }
        }
    }
}

private struct PhotoResultCard: View {
    let photo: ConcertPhoto

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhotoThumbnailView(url: photo.localURL)
                .frame(width: 92, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.fileName)
                    .font(.headline)
                    .lineLimit(2)
                if let date = photo.createdAt {
                    Text(Formatting.timestamp.string(from: date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Capture time missing")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Text(classificationLabel)
                    .font(.subheadline.weight(.semibold))
                if let timingLabel {
                    Text(timingLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(timingColor)
                }
                Text(evidenceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !photo.evidence.boundedCandidateOptions.isEmpty {
                    Text(possibleSongsSummary(photo.evidence.boundedCandidateOptions))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var classificationLabel: String {
        guard let candidate = photo.primaryCandidate else {
            if !photo.evidence.boundedCandidateOptions.isEmpty {
                return "Temporal range - \(photo.evidence.boundedCandidateOptions.count) possible songs"
            }
            return "Unknown - Select candidate"
        }
        return "\(candidate.song.title) - \(photo.classificationStatus.rawValue.capitalized)"
    }

    private var timingLabel: String? {
        switch photo.concertTiming {
        case .beforeConcert:
            "Before concert"
        case .duringConcert:
            "During concert"
        case .afterConcert:
            "After concert"
        case .unknown, nil:
            nil
        }
    }

    private var timingColor: Color {
        switch photo.concertTiming {
        case .beforeConcert, .afterConcert:
            .orange
        default:
            .secondary
        }
    }

    private var evidenceSummary: String {
        var parts: [String] = []
        if let source = photo.evidence.classificationSource {
            parts.append(source.displayName)
        }
        if let support = photo.evidence.neighboringVideoSupport {
            parts.append("timeline \(Int(support * 100))%")
        }
        if photo.evidence.isUserConfirmed {
            parts.append("user confirmed")
        }
        return parts.isEmpty ? "No reliable evidence yet" : parts.joined(separator: " • ")
    }
}

private struct VideoResultCard: View {
    let video: ConcertVideo
    let onCorrect: (SongSegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VideoThumbnailView(url: video.localURL)
                    .frame(width: 92, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.fileName)
                        .font(.headline)
                        .lineLimit(2)
                    if let date = video.createdAt {
                        Text(Formatting.timestamp.string(from: date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Recording time missing")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Text(Formatting.duration(video.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TimelineBar(duration: video.duration, segments: video.segments)
                .frame(height: 28)

            ForEach(video.segments) { segment in
                SegmentRow(segment: segment, videoURL: video.localURL) {
                    onCorrect(segment)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SegmentRow: View {
    let segment: SongSegment
    let videoURL: URL
    let onCorrect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Formatting.duration(segment.startTime))-\(Formatting.duration(segment.endTime))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    Text(evidenceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCorrect) {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Correct segment")
            }
            if !segment.evidence.boundedCandidateOptions.isEmpty {
                Text(possibleSongsSummary(segment.evidence.boundedCandidateOptions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !segment.alternativeCandidates.isEmpty {
                Text("Alternatives: " + segment.alternativeCandidates.map { "\($0.song.title) - \($0.confidenceLabel.rawValue.capitalized)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        switch segment.status {
        case .transition:
            let from = segment.primaryCandidate?.song.title ?? "Unknown"
            let to = segment.alternativeCandidates.first?.song.title ?? "Unknown"
            return "\(from) → \(to) — Transition"
        case .unknown:
            if !segment.evidence.boundedCandidateOptions.isEmpty {
                return "Temporal range — \(segment.evidence.boundedCandidateOptions.count) possible songs"
            }
            return "Unknown — Select candidate"
        case .speech:
            return "Speech/interlude"
        default:
            let candidate = segment.primaryCandidate
            let confidence = candidate?.confidenceLabel.rawValue.capitalized ?? segment.status.rawValue.capitalized
            return "\(candidate?.song.title ?? "Unknown") — \(confidence)"
        }
    }

    private var evidenceSummary: String {
        var parts: [String] = []
        if let source = segment.evidence.classificationSource {
            parts.append(source.displayName)
        }
        if segment.evidence.shazamWindowCount > 0 {
            parts.append("\(segment.evidence.shazamWindowCount) Shazam windows")
        }
        if let phonetic = segment.evidence.phoneticSimilarity {
            parts.append("phonetic \(Int(phonetic * 100))%")
        }
        if segment.evidence.isUserConfirmed {
            parts.append("user confirmed")
        }
        return parts.isEmpty ? "No reliable evidence yet" : parts.joined(separator: " • ")
    }
}

private func possibleSongsSummary(_ candidates: [SongCandidate]) -> String {
    let titles = candidates.map { $0.song.title }
    if titles.count <= 8 {
        return "Possible songs: " + titles.joined(separator: ", ")
    }
    let visible = titles.prefix(8).joined(separator: ", ")
    return "Possible songs: \(visible), +\(titles.count - 8) more"
}

private extension ClassificationSource {
    var displayName: String {
        switch self {
        case .shazamKit:
            "ShazamKit"
        case .temporalPositioning:
            "Temporal positioning"
        case .lyrics:
            "Lyrics"
        case .userCorrection:
            "User correction"
        }
    }
}

private struct TimelineBar: View {
    let duration: TimeInterval
    let segments: [SongSegment]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(color(for: segment.status))
                        .frame(width: max(2, geometry.size.width * CGFloat((segment.endTime - segment.startTime) / max(duration, 1))))
                        .overlay(alignment: .center) {
                            if segment.endTime - segment.startTime > duration * 0.18 {
                                Text(shortLabel(segment))
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 3)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func color(for status: SegmentStatus) -> Color {
        switch status {
        case .identified, .userConfirmed: .green
        case .likely: .blue
        case .possible: .orange
        case .transition: .purple
        case .speech: .gray
        case .unknown: .secondary
        }
    }

    private func shortLabel(_ segment: SongSegment) -> String {
        if segment.status == .transition { return "Transition" }
        return segment.primaryCandidate?.song.title ?? segment.status.rawValue.capitalized
    }
}

private struct PhotoThumbnailView: View {
    let url: URL

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VideoThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            image = await makeThumbnail()
        }
    }

    private func makeThumbnail() async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 180)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private final class ResultsViewModelHolder: ObservableObject {
    @Published var viewModel: ResultsViewModel?
}
