import ConcertSongFinderCore
import SwiftUI

struct SongClipsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var concerts: [ConcertRecord] = []
    @State private var searchText = ""
    @State private var filter: ClipFilter = .all
    @State private var shareRequest: MediaShareRequest?
    @State private var errorMessage: String?

    private var clips: [SongClipItem] {
        concerts.flatMap { concert in
            concert.videos.flatMap { video in
                if video.segments.isEmpty {
                    return [SongClipItem(concert: concert, video: video, segment: nil)]
                }
                return video.segments.map { SongClipItem(concert: concert, video: video, segment: $0) }
            }
        }
    }

    private var filteredClips: [SongClipItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return clips.filter { item in
            filter.includes(item)
                && (query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(query)
                    || item.artist.localizedCaseInsensitiveContains(query)
                    || item.concert.displayTitle.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        CSFScreen {
            VStack(alignment: .leading, spacing: 4) {
                Text("Song Clips")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                Text("\(clips.count) segments across your archive")
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }

            CSFSearchField(text: $searchText, prompt: "Search song or artist")

            Picker("Clip filter", selection: $filter) {
                ForEach(ClipFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .tint(CSFDesign.primary)

            if let errorMessage {
                CSFCard {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(CSFDesign.amber)
                }
            }

            if filteredClips.isEmpty {
                CSFCard(padding: 22) {
                    CSFHeroLead(
                        icon: "music.note.list",
                        title: searchText.isEmpty ? "No song clips yet" : "No matching clips",
                        subtitle: "Analyzed segments will appear here with confidence, status, and share actions.",
                        tint: CSFDesign.violet
                    )
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(filteredClips) { item in
                        Button {
                            shareRequest = shareRequest(for: item)
                        } label: {
                            SongClipCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { loadConcerts() }
        .refreshable { loadConcerts() }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
    }

    private func loadConcerts() {
        do {
            concerts = try environment.concertLibraryStore.loadConcerts().sorted { $0.updatedAt > $1.updatedAt }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load song clips."
        }
    }

    private func shareRequest(for item: SongClipItem) -> MediaShareRequest {
        MediaShareRequest(
            media: .video(item.video),
            context: MediaShareContext(
                songTitle: item.segment?.primaryCandidate?.song.title,
                artist: item.segment?.primaryCandidate?.song.artist ?? item.concert.selectedSetlist?.artistName ?? item.concert.selectedConcert?.artistName,
                venue: item.concert.selectedSetlist?.venueName ?? item.concert.selectedConcert?.venueName,
                eventDate: item.concert.concertDate
            )
        )
    }
}

private struct SongClipItem: Identifiable {
    let concert: ConcertRecord
    let video: ConcertVideo
    let segment: SongSegment?

    var id: String {
        "\(concert.id.uuidString)-\(video.id.uuidString)-\(segment?.id.uuidString ?? "whole")"
    }

    var title: String {
        segment?.primaryCandidate?.song.title ?? "Unknown Segment"
    }

    var artist: String {
        segment?.primaryCandidate?.song.artist ?? "Possible transition or interlude"
    }

    var confidence: Int {
        guard let segment else { return 0 }
        if let score = segment.primaryCandidate?.evidenceScore {
            return Int((score * 100).rounded())
        }
        switch segment.status {
        case .identified, .userConfirmed: return 98
        case .likely: return 86
        case .possible, .transition, .speech: return 58
        case .unknown: return 24
        }
    }

    var statusText: String {
        guard let segment else { return "Imported" }
        switch segment.status {
        case .identified: return "Identified"
        case .userConfirmed: return "Corrected"
        case .likely: return "Aligned"
        case .possible: return "Needs Review"
        case .transition: return "Transition"
        case .speech: return "Speech"
        case .unknown: return "Unknown"
        }
    }

    var timeRange: String {
        guard let segment else { return Formatting.duration(video.duration) }
        return "\(Formatting.duration(segment.startTime))-<\(Formatting.duration(segment.endTime))"
            .replacingOccurrences(of: "-<", with: "–")
    }
}

private enum ClipFilter: String, CaseIterable, Identifiable {
    case all
    case identified
    case review
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .identified: "Identified"
        case .review: "Needs review"
        case .unknown: "Unknown"
        }
    }

    func includes(_ item: SongClipItem) -> Bool {
        switch self {
        case .all:
            true
        case .identified:
            ["Identified", "Corrected", "Aligned"].contains(item.statusText)
        case .review:
            ["Needs Review", "Transition", "Speech"].contains(item.statusText)
        case .unknown:
            item.statusText == "Unknown"
        }
    }
}

private struct SongClipCard: View {
    let item: SongClipItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                StagePoster()
                Text("\(item.confidence)%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.46), in: Capsule())
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(CSFDesign.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(CSFDesign.textMuted)
                }
                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.14), in: Capsule())
                    Text("\(item.timeRange) • \(item.concert.displayTitle)")
                        .font(.caption)
                        .foregroundStyle(CSFDesign.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous)
                .stroke(CSFDesign.line)
        }
    }

    private var statusColor: Color {
        switch item.statusText {
        case "Unknown":
            return CSFDesign.textMuted
        case "Needs Review", "Transition", "Speech":
            return CSFDesign.amber
        default:
            return CSFDesign.primary
        }
    }
}
