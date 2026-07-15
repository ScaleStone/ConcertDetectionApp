import AVFoundation
import AVKit
import ConcertSongFinderCore
import SwiftUI
import UIKit

struct MyConcertsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var concerts: [ConcertRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section("My Concerts") {
                if concerts.isEmpty {
                    ContentUnavailableView("No concerts yet", systemImage: "music.mic", description: Text("Upload concert media to create your first concert."))
                } else {
                    ForEach(concerts) { concert in
                        NavigationLink { ConcertDetailView(concert: concert) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(concert.displayTitle).font(.headline)
                                if !concert.displaySubtitle.isEmpty {
                                    Text(concert.displaySubtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text("\(concert.videos.count) videos • \(concert.photos.count) photos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteConcerts)
                }
            }
        }
        .navigationTitle("My Concerts")
        .task { loadConcerts() }
        .refreshable { loadConcerts() }
    }

    private func loadConcerts() {
        do {
            concerts = try environment.concertLibraryStore.loadConcerts().sorted { $0.updatedAt > $1.updatedAt }
            errorMessage = nil
            AppLog.concertLibrary.info("My Concerts loaded count=\(concerts.count, privacy: .public)")
        } catch {
            errorMessage = "Could not load My Concerts."
            AppLog.concertLibrary.error("My Concerts load failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteConcerts(at offsets: IndexSet) {
        for index in offsets {
            let concert = concerts[index]
            do {
                try environment.concertLibraryStore.deleteConcert(id: concert.id)
                AppLog.concertLibrary.info("Deleted concert from My Concerts concert=\(concert.id.uuidString, privacy: .public)")
            } catch {
                errorMessage = "Could not delete concert."
                AppLog.concertLibrary.error("Delete concert failed concert=\(concert.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        loadConcerts()
    }
}

private struct ConcertDetailView: View {
    let concert: ConcertRecord

    var body: some View {
        List {
            Section("Concert") {
                LabeledContent("Artist", value: concert.displayTitle)
                if !concert.displaySubtitle.isEmpty { LabeledContent("Details", value: concert.displaySubtitle) }
                LabeledContent("Videos", value: "\(concert.videos.count)")
                LabeledContent("Photos", value: "\(concert.photos.count)")
            }
            if let setlist = concert.selectedSetlist, !setlist.occurrences.isEmpty {
                Section("Setlist") {
                    ForEach(setlist.occurrences) { occurrence in
                        let group = SongMediaGroup(occurrence: occurrence, concert: concert)
                        NavigationLink { SongMediaView(concert: concert, group: group) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(occurrence.overallIndex + 1). \(occurrence.title)").font(.headline)
                                    Text(occurrence.artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.videoSegments.count + group.photos.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Setlist unavailable", systemImage: "music.note.list", description: Text("This concert needs a detected or selected setlist before it can be organized by song."))
                }
            }
            let unknown = UnknownMediaGroup(concert: concert)
            if !unknown.videos.isEmpty || !unknown.photos.isEmpty {
                Section("Needs Review") {
                    NavigationLink { UnknownMediaView(group: unknown) } label: {
                        Label("\(unknown.videos.count) videos • \(unknown.photos.count) photos", systemImage: "questionmark.circle")
                    }
                }
            }
        }
        .navigationTitle(concert.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            AppLog.concertLibrary.info("Concert detail appeared concert=\(concert.id.uuidString, privacy: .public) videos=\(concert.videos.count, privacy: .public) photos=\(concert.photos.count, privacy: .public) setlistSongs=\(concert.selectedSetlist?.occurrences.count ?? 0, privacy: .public)")
        }
    }
}

private struct SongMediaView: View {
    let concert: ConcertRecord
    let group: SongMediaGroup
    @State private var selectedVideo: ConcertVideo?
    @State private var selectedPhoto: ConcertPhoto?

    var body: some View {
        List {
            if group.videoSegments.isEmpty && group.photos.isEmpty {
                Section { ContentUnavailableView("No media for this song", systemImage: "photo.on.rectangle") }
            }
            if !group.videoSegments.isEmpty {
                Section("Videos") {
                    ForEach(group.videoSegments) { item in
                        Button {
                            selectedVideo = item.video
                            AppLog.concertLibrary.info("Opening video from song media concert=\(concert.id.uuidString, privacy: .public) video=\(item.video.id.uuidString, privacy: .public) song=\(group.occurrence.title, privacy: .public)")
                        } label: { VideoMediaRow(video: item.video, segment: item.segment) }
                    }
                }
            }
            if !group.photos.isEmpty {
                Section("Photos") {
                    ForEach(group.photos) { photo in
                        Button {
                            selectedPhoto = photo
                            AppLog.concertLibrary.info("Opening photo from song media concert=\(concert.id.uuidString, privacy: .public) photo=\(photo.id.uuidString, privacy: .public) song=\(group.occurrence.title, privacy: .public)")
                        } label: { PhotoMediaRow(photo: photo) }
                    }
                }
            }
        }
        .navigationTitle(group.occurrence.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedVideo) { VideoPlayerSheet(video: $0) }
        .sheet(item: $selectedPhoto) { PhotoViewerSheet(photo: $0) }
    }
}

private struct UnknownMediaView: View {
    let group: UnknownMediaGroup
    @State private var selectedVideo: ConcertVideo?
    @State private var selectedPhoto: ConcertPhoto?

    var body: some View {
        List {
            if !group.videos.isEmpty {
                Section("Videos") { ForEach(group.videos) { video in Button { selectedVideo = video } label: { VideoMediaRow(video: video, segment: nil) } } }
            }
            if !group.photos.isEmpty {
                Section("Photos") { ForEach(group.photos) { photo in Button { selectedPhoto = photo } label: { PhotoMediaRow(photo: photo) } } }
            }
        }
        .navigationTitle("Needs Review")
        .sheet(item: $selectedVideo) { VideoPlayerSheet(video: $0) }
        .sheet(item: $selectedPhoto) { PhotoViewerSheet(photo: $0) }
    }
}

private struct VideoMediaRow: View {
    let video: ConcertVideo
    let segment: SongSegment?

    var body: some View {
        HStack(spacing: 12) {
            LibraryVideoThumbnailView(url: video.localURL).frame(width: 92, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.fileName).font(.headline).lineLimit(2)
                if let segment { Text("\(Formatting.duration(segment.startTime))-\(Formatting.duration(segment.endTime))").font(.subheadline).foregroundStyle(.secondary) }
                Text(Formatting.duration(video.duration)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhotoMediaRow: View {
    let photo: ConcertPhoto

    var body: some View {
        HStack(spacing: 12) {
            LibraryPhotoThumbnailView(url: photo.localURL).frame(width: 92, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.fileName).font(.headline).lineLimit(2)
                Text(photo.primaryCandidate?.song.title ?? photo.classificationStatus.rawValue.capitalized).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct VideoPlayerSheet: View {
    let video: ConcertVideo
    @State private var player: AVPlayer

    init(video: ConcertVideo) {
        self.video = video
        _player = State(initialValue: AVPlayer(url: video.localURL))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .navigationTitle(video.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    AppLog.concertLibrary.info("Video player appeared video=\(video.id.uuidString, privacy: .public) file=\(video.fileName, privacy: .public)")
                    player.play()
                }
                .onDisappear {
                    player.pause()
                    AppLog.concertLibrary.info("Video player disappeared video=\(video.id.uuidString, privacy: .public)")
                }
        }
    }
}

private struct PhotoViewerSheet: View {
    let photo: ConcertPhoto

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: photo.localURL.path) {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo").foregroundStyle(.white)
                }
            }
            .navigationTitle(photo.fileName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct LibraryPhotoThumbnailView: View {
    let url: URL
    var body: some View {
        ZStack {
            Rectangle().fill(.thinMaterial)
            if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
    }
}

private struct LibraryVideoThumbnailView: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.thinMaterial)
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
        }
        .task { image = await makeThumbnail() }
    }

    private func makeThumbnail() async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 180)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private struct SongMediaGroup {
    let occurrence: SetlistOccurrence
    let videoSegments: [VideoSegmentItem]
    let photos: [ConcertPhoto]

    init(occurrence: SetlistOccurrence, concert: ConcertRecord) {
        self.occurrence = occurrence
        self.videoSegments = concert.videos.flatMap { video in
            video.segments.compactMap { segment in Self.segment(segment, matches: occurrence) ? VideoSegmentItem(video: video, segment: segment) : nil }
        }
        self.photos = concert.photos.filter { photo in
            guard let candidate = photo.primaryCandidate else { return false }
            return Self.matchesCandidate(candidate, occurrence: occurrence)
        }
    }

    private static func segment(_ segment: SongSegment, matches occurrence: SetlistOccurrence) -> Bool {
        if let primaryCandidate = segment.primaryCandidate, matchesCandidate(primaryCandidate, occurrence: occurrence) { return true }
        return segment.alternativeCandidates.contains { matchesCandidate($0, occurrence: occurrence) }
    }

    private static func matchesCandidate(_ candidate: SongCandidate, occurrence: SetlistOccurrence) -> Bool {
        if candidate.setlistOccurrenceID == occurrence.id { return true }
        let candidateKey = TextNormalizer.normalizedSongKey(title: candidate.song.title, artist: candidate.song.artist)
        let occurrenceKey = TextNormalizer.normalizedSongKey(title: occurrence.title, artist: occurrence.artist)
        return candidateKey == occurrenceKey
    }
}

private struct VideoSegmentItem: Identifiable {
    let id: UUID
    let video: ConcertVideo
    let segment: SongSegment

    init(video: ConcertVideo, segment: SongSegment) {
        self.id = segment.id
        self.video = video
        self.segment = segment
    }
}

private struct UnknownMediaGroup {
    let videos: [ConcertVideo]
    let photos: [ConcertPhoto]

    init(concert: ConcertRecord) {
        self.videos = concert.videos.filter { video in
            video.segments.isEmpty || video.segments.contains { $0.primaryCandidate == nil && $0.evidence.boundedCandidateOptions.isEmpty }
        }
        self.photos = concert.photos.filter { photo in
            photo.primaryCandidate == nil && photo.evidence.boundedCandidateOptions.isEmpty
        }
    }
}
