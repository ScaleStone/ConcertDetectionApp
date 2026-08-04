import ConcertSongFinderCore
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("CSFAutoMatchNewVideos") private var autoMatchNewVideos = true
    @AppStorage("CSFNotifyWhenAnalysisFinishes") private var notifyWhenAnalysisFinishes = true
    @State private var concerts: [ConcertRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        CSFScreen {
            profileHero
            statsGrid
            mostHeardSection
            matchingSection
            privacySection
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { loadConcerts() }
        .refreshable { loadConcerts() }
    }

    private var profileHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                StagePoster()
                    .frame(height: 176)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .horizontal)
                avatar
                    .offset(y: 46)
                    .padding(.leading, 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Mia Rivera")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                Text("Front row since 2019 • London")
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }
            .padding(.top, 56)
        }
    }

    private var avatar: some View {
        Text("MR")
            .font(.title2.weight(.bold))
            .foregroundStyle(CSFDesign.textPrimary)
            .frame(width: 82, height: 82)
            .background(CSFDesign.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(CSFDesign.pageBackground, lineWidth: 5)
            }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ProfileStatTile(icon: "calendar", value: "\(concerts.count)", label: "Concerts")
            ProfileStatTile(icon: "music.note", value: "\(songsFound)", label: "Songs found")
            ProfileStatTile(icon: "video", value: "\(clipCount)", label: "Clips")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your stats")
    }

    private var mostHeardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CSFSectionHeader(title: "Most heard live")
            CSFCard(padding: 0) {
                VStack(spacing: 0) {
                    let artists = mostHeardArtists
                    if artists.isEmpty {
                        Text("Your most-heard artists will appear after analysis.")
                            .font(.subheadline)
                            .foregroundStyle(CSFDesign.textMuted)
                            .padding(16)
                    } else {
                        ForEach(Array(artists.enumerated()), id: \.element.name) { index, artist in
                            ProfileRankRow(rank: index + 1, title: artist.name, count: "\(artist.count) songs")
                            if index < artists.count - 1 {
                                Divider().overlay(CSFDesign.line)
                            }
                        }
                    }
                }
            }
        }
    }

    private var matchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CSFSectionHeader(title: "Matching")
            CSFCard(padding: 0) {
                VStack(spacing: 0) {
                    ToggleRow(icon: "bolt.badge.automatic", title: "Auto-match new videos", isOn: $autoMatchNewVideos)
                    Divider().overlay(CSFDesign.line)
                    ToggleRow(icon: "bell", title: "Notify when analysis finishes", isOn: $notifyWhenAnalysisFinishes)
                    Divider().overlay(CSFDesign.line)
                    NavigationLink {
                        PostIdeasPreferenceView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .frame(width: 24)
                                .foregroundStyle(CSFDesign.violet)
                            Text("Caption idea preferences")
                                .foregroundStyle(CSFDesign.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CSFDesign.textMuted)
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CSFSectionHeader(title: "Privacy")
            CSFCard {
                Label {
                    Text("Audio fingerprints are matched on device. Your videos never leave this iPhone unless you share a clip yourself.")
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.textMuted)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(CSFDesign.violet)
                }

                Button {
                    clearHistory()
                } label: {
                    Label("Clear match history", systemImage: "trash")
                }
                .buttonStyle(CSFSecondaryButtonStyle())
                .foregroundStyle(CSFDesign.amber)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(CSFDesign.amber)
                }
            }
        }
    }

    private var songsFound: Int {
        Set(concerts.flatMap(\.videos).flatMap(\.segments).compactMap { $0.primaryCandidate?.song.id }).count
    }

    private var clipCount: Int {
        concerts.reduce(0) { total, concert in
            total + concert.videos.reduce(0) { $0 + max($1.segments.count, 1) } + concert.photos.count
        }
    }

    private var mostHeardArtists: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for concert in concerts {
            for video in concert.videos {
                for segment in video.segments {
                    if let artist = segment.primaryCandidate?.song.artist {
                        counts[artist, default: 0] += 1
                    }
                }
            }
        }
        let ranked = counts.map { (name: $0.key, count: $0.value) }
        return Array(ranked.sorted { left, right in
            left.count == right.count ? left.name < right.name : left.count > right.count
        }.prefix(3))
    }

    private func loadConcerts() {
        do {
            concerts = try environment.concertLibraryStore.loadConcerts()
            errorMessage = nil
        } catch {
            errorMessage = "Could not load profile stats."
        }
    }

    private func clearHistory() {
        do {
            for concert in concerts {
                try environment.concertLibraryStore.deleteConcert(id: concert.id)
            }
            try environment.historyStore.saveRecords([])
            concerts = []
            errorMessage = nil
        } catch {
            errorMessage = "Could not clear match history."
        }
    }
}

private struct ProfileStatTile: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CSFDesign.violet)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(CSFDesign.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(CSFDesign.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 102)
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: CSFDesign.cardRadius, style: .continuous))
    }
}

private struct ProfileRankRow: View {
    let rank: Int
    let title: String
    let count: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CSFDesign.textMuted)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(CSFDesign.textPrimary)
            Spacer()
            Text(count)
                .font(.caption)
                .foregroundStyle(CSFDesign.textMuted)
        }
        .padding(16)
    }
}

private struct ToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(CSFDesign.textPrimary)
        }
        .padding(16)
        .tint(CSFDesign.primary)
    }
}

private struct PostIdeasPreferenceView: View {
    @AppStorage("CSFShowAIScores") private var showAIScores = false

    var body: some View {
        CSFScreen {
            Text("Post Ideas")
                .font(.largeTitle.weight(.bold))
            CSFCard {
                Toggle("Show AI Scores (Testing)", isOn: $showAIScores)
                    .tint(CSFDesign.primary)
                Text("Caption ideas use concert metadata and song identifiers. Full video and audio stay on device.")
                    .font(.subheadline)
                    .foregroundStyle(CSFDesign.textMuted)
            }
        }
        .navigationTitle("Caption ideas")
        .navigationBarTitleDisplayMode(.inline)
    }
}
