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
                cleanUpOrphanedMediaFiles(for: concert)
                AppLog.concertLibrary.info("Deleted concert from My Concerts concert=\(concert.id.uuidString, privacy: .public)")
            } catch {
                errorMessage = "Could not delete concert."
                AppLog.concertLibrary.error("Delete concert failed concert=\(concert.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        loadConcerts()
    }

    /// Removes the deleted concert's imported media files unless another
    /// concert or a saved analysis still references them.
    private func cleanUpOrphanedMediaFiles(for concert: ConcertRecord) {
        let candidateURLs = Set(concert.videos.map(\.localURL) + concert.photos.map(\.localURL))
        guard !candidateURLs.isEmpty else { return }

        var referencedPaths: Set<String> = []
        if let remainingConcerts = try? environment.concertLibraryStore.loadConcerts() {
            for other in remainingConcerts where other.id != concert.id {
                referencedPaths.formUnion(other.videos.map(\.localURL.path))
                referencedPaths.formUnion(other.photos.map(\.localURL.path))
            }
        }
        if let records = try? environment.historyStore.loadRecords() {
            for record in records {
                referencedPaths.formUnion(record.videos.map(\.localURL.path))
                referencedPaths.formUnion(record.photos.map(\.localURL.path))
            }
        }

        for url in candidateURLs where !referencedPaths.contains(url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                AppLog.concertLibrary.info("Removed orphaned media file \(url.lastPathComponent, privacy: .public)")
            } catch {
                AppLog.concertLibrary.error("Could not remove orphaned media file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
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
            let recognizedGroups = ConcertMediaGrouping.recognizedSongGroups(
                videos: concert.videos,
                photos: concert.photos,
                setlist: concert.selectedSetlist
            )
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
            } else if recognizedGroups.isEmpty {
                Section {
                    ContentUnavailableView("Setlist unavailable", systemImage: "music.note.list", description: Text("This concert needs a detected or selected setlist before it can be organized by song."))
                }
            }
            // Reliably recognized songs that aren't on the setlist (covers,
            // openers, or concerts where setlist lookup failed) still get a
            // browsable song label instead of vanishing into Needs Review.
            if !recognizedGroups.isEmpty {
                Section(concert.selectedSetlist == nil ? "Recognized Songs" : "Other Recognized Songs") {
                    ForEach(recognizedGroups) { group in
                        NavigationLink { RecognizedSongMediaView(concert: concert, group: group) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.song.title).font(.headline)
                                    Text(group.song.artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.videoSegments.count + group.photos.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let unknown = UnknownMediaGroup(concert: concert, recognizedGroups: recognizedGroups)
            if !unknown.videos.isEmpty || !unknown.photos.isEmpty {
                Section("Needs Review") {
                    NavigationLink { UnknownMediaView(concert: concert, group: unknown) } label: {
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
    @State private var shareRequest: MediaShareRequest?

    private var shareContext: MediaShareContext {
        MediaShareContext(
            songTitle: group.occurrence.title,
            artist: group.occurrence.artist,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate
        )
    }

    var body: some View {
        List {
            if group.videoSegments.isEmpty && group.photos.isEmpty {
                Section { ContentUnavailableView("No media for this song", systemImage: "photo.on.rectangle") }
            }
            if !group.videoSegments.isEmpty {
                Section("Videos") {
                    ForEach(group.videoSegments) { item in
                        ShareableMediaRow {
                            VideoMediaRow(video: item.video, segment: item.segment)
                        } onOpen: {
                            selectedVideo = item.video
                            AppLog.concertLibrary.info("Opening video from song media concert=\(concert.id.uuidString, privacy: .public) video=\(item.video.id.uuidString, privacy: .public) song=\(group.occurrence.title, privacy: .public)")
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .video(item.video), context: shareContext)
                        }
                    }
                }
            }
            if !group.photos.isEmpty {
                Section("Photos") {
                    ForEach(group.photos) { photo in
                        ShareableMediaRow {
                            PhotoMediaRow(photo: photo)
                        } onOpen: {
                            selectedPhoto = photo
                            AppLog.concertLibrary.info("Opening photo from song media concert=\(concert.id.uuidString, privacy: .public) photo=\(photo.id.uuidString, privacy: .public) song=\(group.occurrence.title, privacy: .public)")
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .photo(photo), context: shareContext)
                        }
                    }
                }
            }
        }
        .navigationTitle(group.occurrence.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedVideo) { VideoPlayerSheet(video: $0, shareContext: shareContext) }
        .sheet(item: $selectedPhoto) { PhotoViewerSheet(photo: $0, shareContext: shareContext) }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
    }
}

private struct UnknownMediaView: View {
    let concert: ConcertRecord
    let group: UnknownMediaGroup
    @State private var selectedVideo: ConcertVideo?
    @State private var selectedPhoto: ConcertPhoto?
    @State private var shareRequest: MediaShareRequest?

    /// No song identification here, so the share tag carries the concert
    /// context only (artist/venue/date when known).
    private var shareContext: MediaShareContext {
        MediaShareContext(
            songTitle: nil,
            artist: concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate
        )
    }

    var body: some View {
        List {
            if !group.videos.isEmpty {
                Section("Videos") {
                    ForEach(group.videos) { video in
                        ShareableMediaRow {
                            VideoMediaRow(video: video, segment: nil)
                        } onOpen: {
                            selectedVideo = video
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .video(video), context: shareContext)
                        }
                    }
                }
            }
            if !group.photos.isEmpty {
                Section("Photos") {
                    ForEach(group.photos) { photo in
                        ShareableMediaRow {
                            PhotoMediaRow(photo: photo)
                        } onOpen: {
                            selectedPhoto = photo
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .photo(photo), context: shareContext)
                        }
                    }
                }
            }
        }
        .navigationTitle("Needs Review")
        .sheet(item: $selectedVideo) { VideoPlayerSheet(video: $0, shareContext: shareContext) }
        .sheet(item: $selectedPhoto) { PhotoViewerSheet(photo: $0, shareContext: shareContext) }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
    }
}

/// A media list row with a tappable content area (opens the viewer) and a
/// visible share button on the trailing edge.
private struct ShareableMediaRow<Content: View>: View {
    @ViewBuilder let content: Content
    let onOpen: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share")
        }
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
    let shareContext: MediaShareContext?
    @State private var player: AVPlayer
    @State private var shareRequest: MediaShareRequest?

    init(video: ConcertVideo, shareContext: MediaShareContext? = nil) {
        self.video = video
        self.shareContext = shareContext
        _player = State(initialValue: AVPlayer(url: video.localURL))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .navigationTitle(video.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let shareContext {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                shareRequest = MediaShareRequest(media: .video(video), context: shareContext)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share video")
                        }
                    }
                }
                .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
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
    let shareContext: MediaShareContext?
    @State private var shareRequest: MediaShareRequest?

    init(photo: ConcertPhoto, shareContext: MediaShareContext? = nil) {
        self.photo = photo
        self.shareContext = shareContext
    }

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
            .toolbar {
                if let shareContext {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            shareRequest = MediaShareRequest(media: .photo(photo), context: shareContext)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share photo")
                    }
                }
            }
            .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
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
        ConcertMediaGrouping.candidateMatches(candidate, occurrence: occurrence)
    }
}

/// Media list for a recognized song that isn't on the setlist.
private struct RecognizedSongMediaView: View {
    let concert: ConcertRecord
    let group: ConcertMediaGrouping.RecognizedSongGroup
    @State private var selectedVideo: ConcertVideo?
    @State private var selectedPhoto: ConcertPhoto?
    @State private var shareRequest: MediaShareRequest?

    private var shareContext: MediaShareContext {
        MediaShareContext(
            songTitle: group.song.title,
            artist: group.song.artist,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate
        )
    }

    var body: some View {
        List {
            if !group.videoSegments.isEmpty {
                Section("Videos") {
                    ForEach(group.videoSegments) { item in
                        ShareableMediaRow {
                            VideoMediaRow(video: item.video, segment: item.segment)
                        } onOpen: {
                            selectedVideo = item.video
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .video(item.video), context: shareContext)
                        }
                    }
                }
            }
            if !group.photos.isEmpty {
                Section("Photos") {
                    ForEach(group.photos) { photo in
                        ShareableMediaRow {
                            PhotoMediaRow(photo: photo)
                        } onOpen: {
                            selectedPhoto = photo
                        } onShare: {
                            shareRequest = MediaShareRequest(media: .photo(photo), context: shareContext)
                        }
                    }
                }
            }
        }
        .navigationTitle(group.song.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedVideo) { VideoPlayerSheet(video: $0, shareContext: shareContext) }
        .sheet(item: $selectedPhoto) { PhotoViewerSheet(photo: $0, shareContext: shareContext) }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
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

    /// The exact complement of the media shown under setlist songs and
    /// recognized-song groups: anything that did not land in at least one
    /// song group appears here, so no video or photo can ever become
    /// unreachable in the concert detail view.
    init(concert: ConcertRecord, recognizedGroups: [ConcertMediaGrouping.RecognizedSongGroup]) {
        var matchedVideoIDs: Set<UUID> = []
        var matchedPhotoIDs: Set<UUID> = []
        for occurrence in concert.selectedSetlist?.occurrences ?? [] {
            let group = SongMediaGroup(occurrence: occurrence, concert: concert)
            matchedVideoIDs.formUnion(group.videoSegments.map { $0.video.id })
            matchedPhotoIDs.formUnion(group.photos.map(\.id))
        }
        for group in recognizedGroups {
            matchedVideoIDs.formUnion(group.videoSegments.map { $0.video.id })
            matchedPhotoIDs.formUnion(group.photos.map(\.id))
        }
        self.videos = concert.videos.filter { !matchedVideoIDs.contains($0.id) }
        self.photos = concert.photos.filter { !matchedPhotoIDs.contains($0.id) }
    }
}
