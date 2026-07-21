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

/// Concert detail: a searchable media library grid where every thumbnail is
/// labeled with its song name.
private struct ConcertDetailView: View {
    let concert: ConcertRecord
    @State private var searchText = ""
    @State private var viewerItem: ConcertMediaGrouping.MediaLibraryItem?
    @State private var shareRequest: MediaShareRequest?

    private var allItems: [ConcertMediaGrouping.MediaLibraryItem] {
        ConcertMediaGrouping.libraryItems(
            videos: concert.videos,
            photos: concert.photos,
            setlist: concert.selectedSetlist
        )
    }

    private var filteredItems: [ConcertMediaGrouping.MediaLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allItems }
        return allItems.filter { $0.displayLabel.localizedCaseInsensitiveContains(query) }
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if filteredItems.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle")
                            .padding(.top, 40)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredItems) { item in
                            MediaLibraryCell(item: item)
                                .onTapGesture { viewerItem = item }
                                .contextMenu {
                                    Button {
                                        shareRequest = MediaShareRequest(media: shareMedia(for: item), context: shareContext(for: item))
                                    } label: {
                                        Label("Share…", systemImage: "square.and.arrow.up")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }

                if let attribution = concert.selectedSetlist?.attributionURL {
                    Link("Setlist data attribution", destination: attribution)
                        .font(.caption)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(concert.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search by song name")
        .sheet(item: $viewerItem) { item in
            switch item.media {
            case .video(let video, _):
                VideoPlayerSheet(video: video, shareContext: shareContext(for: item))
            case .photo(let photo):
                PhotoViewerSheet(photo: photo, shareContext: shareContext(for: item))
            }
        }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
        .onAppear {
            AppLog.concertLibrary.info("Concert detail appeared concert=\(concert.id.uuidString, privacy: .public) items=\(allItems.count, privacy: .public)")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !concert.displaySubtitle.isEmpty {
                Text(concert.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(concert.videos.count) videos • \(concert.photos.count) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func shareMedia(for item: ConcertMediaGrouping.MediaLibraryItem) -> MediaShareRequest.Media {
        switch item.media {
        case .video(let video, _): return .video(video)
        case .photo(let photo): return .photo(photo)
        }
    }

    private func shareContext(for item: ConcertMediaGrouping.MediaLibraryItem) -> MediaShareContext {
        MediaShareContext(
            songTitle: item.songTitle,
            artist: item.songArtist ?? concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate
        )
    }
}

/// A square thumbnail labeled with the item's song name.
private struct MediaLibraryCell: View {
    let item: ConcertMediaGrouping.MediaLibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                thumbnail
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if case .video(let video, let segment) = item.media {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        Text(Formatting.duration(segment.map { $0.endTime - $0.startTime } ?? video.duration))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
            }

            Text(item.displayLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(item.songTitle == nil ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.songTitle ?? "Unknown song"), \(isVideo ? "video" : "photo")")
    }

    private var isVideo: Bool {
        if case .video = item.media { return true }
        return false
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.media {
        case .video(let video, let segment):
            // Thumbnail from the middle of the song's segment so multi-song
            // videos show a distinct frame per song entry.
            LibraryVideoThumbnailView(
                url: video.localURL,
                at: segment.map { ($0.startTime + $0.endTime) / 2 } ?? 0
            )
        case .photo(let photo):
            LibraryPhotoThumbnailView(url: photo.localURL)
        }
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
    var at: TimeInterval = 0
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.thinMaterial)
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
        }
        .task { image = await makeThumbnail() }
    }

    private func makeThumbnail() async -> UIImage? {
        let seconds = at
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 180)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                // Fall back to the first frame if the seek fails.
                return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
