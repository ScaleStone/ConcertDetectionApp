import AVFoundation
import ConcertSongFinderCore
import PhotosUI
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModelHolder = ViewModelHolder()
    var isActive: Bool = true
    let onImported: (ConcertMediaImport) -> Void

    var body: some View {
        Group {
            if let viewModel = viewModelHolder.viewModel {
                HomeContentView(viewModel: viewModel, isActive: isActive, onImported: onImported)
            } else {
                ProgressView()
                    .task {
                        viewModelHolder.viewModel = HomeViewModel(environment: environment)
                        viewModelHolder.viewModel?.load()
                    }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct HomeContentView: View {
    @ObservedObject var viewModel: HomeViewModel
    let isActive: Bool
    let onImported: (ConcertMediaImport) -> Void
    @State private var focusedUploadItemID: UploadFeedItem.ID?

    var body: some View {
        GeometryReader { proxy in
            let feedItems = uploadFeedItems

            ZStack {
                CSFDesign.pageBackground.ignoresSafeArea()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(feedItems) { item in
                            UploadClipPage(
                                item: item,
                                isActive: isActive && (focusedUploadItemID == item.id || (focusedUploadItemID == nil && item.id == feedItems.first?.id)),
                                isImporting: viewModel.isImporting,
                                selectedCount: viewModel.selectedItems.count,
                                picker: uploadPicker,
                                railPicker: railUploadPicker
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $focusedUploadItemID)

                if viewModel.isImporting {
                    importProgress
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack {
                    if let error = viewModel.errorMessage {
                        messageBanner(icon: "exclamationmark.triangle.fill", title: "Import needs attention", message: error, tint: CSFDesign.amber)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    } else {
                        permissionBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    Spacer()
                }
            }
            .onAppear {
                if focusedUploadItemID == nil {
                    focusedUploadItemID = feedItems.first?.id
                }
            }
            .onChange(of: feedItems.map(\.id)) { _, ids in
                if focusedUploadItemID.map({ ids.contains($0) }) != true {
                    focusedUploadItemID = ids.first
                }
            }
        }
        .ignoresSafeArea()
        .refreshable {
            viewModel.load()
        }
        .onChange(of: viewModel.selectedItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                if let mediaImport = await viewModel.importSelectedItems() {
                    onImported(mediaImport)
                }
            }
        }
    }

    private var uploadPicker: some View {
        let pickerTitle = viewModel.isImporting ? "Importing Media" : "Select Concert Media"

        return PhotosPicker(
            selection: Binding(
                get: { viewModel.selectedItems },
                set: { viewModel.selectedItems = $0 }
            ),
            maxSelectionCount: 0,
            matching: .any(of: [.videos, .images])
        ) {
            Label(pickerTitle, systemImage: "plus.circle.fill")
        }
        .buttonStyle(FullUploadButtonStyle())
        .accessibilityLabel(pickerTitle)
        .disabled(viewModel.isImporting)
    }

    private var railUploadPicker: some View {
        let pickerTitle = viewModel.isImporting ? "Importing" : "Import"
        let pickerIcon = viewModel.isImporting ? "hourglass" : "plus"

        return PhotosPicker(
            selection: Binding(
                get: { viewModel.selectedItems },
                set: { viewModel.selectedItems = $0 }
            ),
            maxSelectionCount: 0,
            matching: .any(of: [.videos, .images])
        ) {
            RailActionLabel(icon: pickerIcon, label: pickerTitle)
        }
        .buttonStyle(RailActionButtonStyle())
        .accessibilityLabel(viewModel.isImporting ? "Importing Media" : "Select Concert Media")
        .disabled(viewModel.isImporting)
    }

    private var uploadFeedItems: [UploadFeedItem] {
        let demoItems = UploadFeedItem.demoClips
        if !demoItems.isEmpty { return demoItems }

        let recentVideos = viewModel.recentRecords.flatMap { record in
            record.videos.map { video in
                (record: record, video: video)
            }
        }
        let recentItems = recentVideos.enumerated().map { offset, pair in
                UploadFeedItem(
                    title: pair.video.segments.first?.primaryCandidate?.song.title ?? displayName(for: pair.video),
                    subtitle: pair.record.selectedSetlist?.artistName ?? pair.record.selectedConcert?.artistName ?? "Concert clip",
                    meta: "\(Formatting.duration(pair.video.duration)) • \(pair.video.segments.count) detected segments",
                    status: statusText(for: pair.video),
                    icon: "play.fill",
                    tint: tint(for: pair.video),
                    isRealClip: true,
                    demoClipName: nil,
                    clipIndex: offset + 1,
                    clipTotal: recentVideos.count
                )
        }
        if !recentItems.isEmpty { return recentItems }
        return UploadFeedItem.samples
    }

    private func displayName(for video: ConcertVideo) -> String {
        if video.fileName.count > 28, video.fileName.contains("-") {
            return "Imported concert clip"
        }
        return video.fileName
    }

    private var importProgress: some View {
        CSFCard {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(CSFDesign.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copying media into the app")
                        .font(.headline)
                        .foregroundStyle(CSFDesign.textPrimary)
                    Text("Original videos stay in Photos while local analysis uses app-controlled copies.")
                        .font(.caption)
                        .foregroundStyle(CSFDesign.textPrimary.opacity(0.62))
                }
            }
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch viewModel.permissionState {
        case .denied:
            messageBanner(
                icon: "lock.fill",
                title: "Photo access is denied",
                message: "The picker may still provide selected items where iOS allows it, or you can update access in Settings.",
                tint: CSFDesign.amber
            )
        case .limited:
            messageBanner(
                icon: "photo.badge.checkmark",
                title: "Limited library access",
                message: "Selected media will import when available. Full library access can improve timestamp and location ordering.",
                tint: CSFDesign.blue
            )
        default:
            EmptyView()
        }
    }

    private func statusText(for video: ConcertVideo) -> String {
        if video.segments.contains(where: { $0.status == .unknown }) {
            return "Needs review"
        }
        if video.segments.isEmpty {
            return "Ready to analyze"
        }
        return "Identified"
    }

    private func tint(for video: ConcertVideo) -> Color {
        switch statusText(for: video) {
        case "Needs review":
            return CSFDesign.amber
        case "Identified":
            return CSFDesign.primary
        default:
            return CSFDesign.violet
        }
    }

    private func messageBanner(icon: String, title: String, message: String, tint: Color) -> some View {
        CSFCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(CSFDesign.textPrimary)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.textPrimary.opacity(0.66))
                }
            }
        }
    }
}

private struct UploadFeedItem: Identifiable {
    let title: String
    let subtitle: String
    let meta: String
    let status: String
    let icon: String
    let tint: Color
    let isRealClip: Bool
    let demoClipName: String?
    var clipIndex: Int = 1
    var clipTotal: Int = 1

    var id: String {
        demoClipName ?? "\(title)-\(subtitle)-\(clipIndex)-\(clipTotal)"
    }

    var demoClipURL: URL? {
        guard let demoClipName else { return nil }
        return Bundle.main.url(forResource: demoClipName, withExtension: "mov", subdirectory: "DemoUploadClips")
            ?? Bundle.main.url(forResource: demoClipName, withExtension: "mov")
    }

    static var demoClips: [UploadFeedItem] {
        let clipCount = 10
        return (1...clipCount).compactMap { index in
            let clipName = String(format: "DemoClip%02d", index)
            let url = Bundle.main.url(forResource: clipName, withExtension: "mov", subdirectory: "DemoUploadClips")
                ?? Bundle.main.url(forResource: clipName, withExtension: "mov")
            guard url != nil else {
                return nil
            }
            return UploadFeedItem(
                title: "Concert clip \(index)",
                subtitle: "@concertsongfinder",
                meta: "Swipe up for next clip • \(index) of 10",
                status: "Ready",
                icon: "play.fill",
                tint: index % 3 == 0 ? CSFDesign.amber : (index % 2 == 0 ? CSFDesign.violet : CSFDesign.primary),
                isRealClip: true,
                demoClipName: clipName,
                clipIndex: index,
                clipTotal: clipCount
            )
        }
    }

    static let samples: [UploadFeedItem] = [
        UploadFeedItem(
            title: "Scroll your concert clips",
            subtitle: "Upload Studio",
            meta: "Swipe vertically • import from Photos",
            status: "Ready",
            icon: "hand.draw",
            tint: CSFDesign.primary,
            isRealClip: false,
            demoClipName: nil
        ),
        UploadFeedItem(
            title: "Find the song in every video",
            subtitle: "ShazamKit windows",
            meta: "Overlapping audio scans • transition safe",
            status: "On device",
            icon: "waveform.badge.magnifyingglass",
            tint: CSFDesign.violet,
            isRealClip: false,
            demoClipName: nil
        ),
        UploadFeedItem(
            title: "Recover distorted audio",
            subtitle: "Fallback matching",
            meta: "Setlist order • lyrics • speech cues",
            status: "Phase 2",
            icon: "text.bubble",
            tint: CSFDesign.amber,
            isRealClip: false,
            demoClipName: nil
        )
    ]
}

private struct UploadClipPage<Picker: View, RailPicker: View>: View {
    let item: UploadFeedItem
    let isActive: Bool
    let isImporting: Bool
    let selectedCount: Int
    let picker: Picker
    let railPicker: RailPicker
    @State private var playbackProgress: Double = 0

    var body: some View {
        ZStack {
            if let demoClipURL = item.demoClipURL {
                LoopingDemoVideoPlayer(url: demoClipURL, isActive: isActive, playbackProgress: $playbackProgress)
                    .ignoresSafeArea()
            } else {
                StagePoster()
                    .ignoresSafeArea()
            }

            RadialGradient(
                colors: item.demoClipURL == nil ? [item.tint.opacity(0.30), .clear] : [.clear, .clear],
                center: .center,
                startRadius: 20,
                endRadius: 320
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: item.demoClipURL == nil
                    ? [.black.opacity(0.08), CSFDesign.pageBackground.opacity(0.42), CSFDesign.pageBackground.opacity(0.92)]
                    : [.black.opacity(0.10), .clear, .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if item.demoClipURL != nil {
                LinearGradient(
                    colors: [
                        CSFDesign.violet.opacity(0.24),
                        .clear,
                        CSFDesign.primary.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)
                .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .clear,
                        CSFDesign.pageBackground.opacity(0.08),
                        CSFDesign.pageBackground.opacity(0.62)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                topAtmosphere
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()

                premiumTopChrome
                    .padding(.horizontal, 20)
                    .padding(.top, 58)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                clipProgress
                    .frame(height: 5)
                    .padding(.horizontal, 42)
                    .padding(.bottom, 112)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            VStack {
                if item.demoClipURL == nil {
                    header
                    Spacer()
                    centerPreview
                }
                Spacer()
                bottomOverlay
            }
            .padding(.horizontal, item.demoClipURL == nil ? 22 : 20)
            .padding(.top, item.demoClipURL == nil ? 24 : 54)
            .padding(.bottom, item.demoClipURL == nil ? 96 : 132)

            if item.demoClipURL == nil {
                rightRail
                    .padding(.trailing, 18)
                    .padding(.bottom, 136)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

        }
    }

    private var topAtmosphere: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    CSFDesign.pageBackground.opacity(0.34),
                    CSFDesign.violet.opacity(0.22),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 210)

            HStack(spacing: 0) {
                stageLight(color: CSFDesign.primary, rotation: -24, xOffset: -88)
                Spacer(minLength: 0)
                stageLight(color: CSFDesign.violet, rotation: 22, xOffset: 76)
            }
            .frame(height: 180)
            .padding(.top, -24)

        }
        .allowsHitTesting(false)
    }

    private var premiumTopChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [CSFDesign.primary, CSFDesign.violet],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "waveform")
                        .font(.caption.weight(.black))
                        .foregroundStyle(CSFDesign.textPrimary)
                }
                .frame(width: 28, height: 28)

                Text("ConcertSongFinder")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(CSFDesign.textPrimary.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.42), radius: 14, y: 7)

            Spacer(minLength: 12)

            Text(clipCounterText)
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(CSFDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(item.tint.opacity(0.42))
                }
                .shadow(color: item.tint.opacity(0.26), radius: 14, y: 6)
        }
        .allowsHitTesting(false)
    }

    private var clipProgress: some View {
        GeometryReader { proxy in
            let progress = min(max(playbackProgress, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .fill(CSFDesign.textPrimary.opacity(0.10))
                    }
                    .overlay {
                        Capsule()
                            .stroke(CSFDesign.textPrimary.opacity(0.16), lineWidth: 0.8)
                    }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [item.tint, CSFDesign.violet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, proxy.size.width * progress))
                    .shadow(color: item.tint.opacity(0.34), radius: 8, y: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func stageLight(color: Color, rotation: Double, xOffset: CGFloat) -> some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(0.42),
                        color.opacity(0.14),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 170, height: 250)
            .blur(radius: 24)
            .rotationEffect(.degrees(rotation))
            .offset(x: xOffset, y: -58)
            .blendMode(.screen)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Upload")
                    .font(.title.weight(.bold))
                    .foregroundStyle(CSFDesign.textPrimary)
                Text("Swipe clips")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(2)
                    .foregroundStyle(CSFDesign.textMuted)
            }
            Spacer()
            Text(item.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(item.tint.opacity(0.16), in: Capsule())
        }
    }

    private var centerPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(CSFDesign.deepSurface.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(CSFDesign.textPrimary.opacity(0.08))
                    }
                .shadow(color: item.tint.opacity(0.28), radius: 32)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill((item.demoClipURL == nil ? item.tint.opacity(0.18) : .black.opacity(0.42)))
                        .frame(width: 104, height: 104)
                    Image(systemName: item.icon)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(item.tint)
                }
                if item.demoClipURL == nil {
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(CSFDesign.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.62)
                        Text(item.subtitle)
                            .font(.headline)
                            .foregroundStyle(CSFDesign.textMuted)
                        Text(item.meta)
                            .font(.caption)
                            .foregroundStyle(CSFDesign.textMuted)
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity)
        .frame(height: item.demoClipURL == nil ? 430 : nil)
        .frame(maxHeight: item.demoClipURL == nil ? nil : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: item.demoClipURL == nil ? 34 : 0, style: .continuous))
    }

    private var bottomOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.demoClipURL == nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.isRealClip ? "Recent clip" : "ConcertSongFinder")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(2)
                        .foregroundStyle(CSFDesign.textMuted)
                    Text(item.title)
                        .font(.title.weight(.bold))
                        .foregroundStyle(CSFDesign.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text(item.meta)
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.textMuted)
                }
            }

            if item.demoClipURL == nil {
                picker
            }

            if selectedCount > 0 || isImporting {
                Text(isImporting ? "Copying selected videos..." : "\(selectedCount) item\(selectedCount == 1 ? "" : "s") selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CSFDesign.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clipIndex: Int {
        min(max(item.clipIndex, 1), clipTotal)
    }

    private var clipTotal: Int {
        max(item.clipTotal, 1)
    }

    private var clipCounterText: String {
        if clipTotal > 99 {
            return "\(clipIndex)/99+"
        }
        return "\(clipIndex)/\(clipTotal)"
    }

    private var rightRail: some View {
        VStack(spacing: 20) {
            if item.demoClipURL == nil {
                railButton(icon: "plus.circle.fill", label: "Import")
            } else {
                railPicker
            }
            railButton(icon: "music.note", label: "Songs")
            railButton(icon: "lock.shield", label: "Private")
        }
    }

    private func railButton(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(CSFDesign.textPrimary)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(CSFDesign.textPrimary.opacity(0.18))
                }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CSFDesign.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LoopingDemoVideoPlayer: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    @Binding var playbackProgress: Double

    func makeUIView(context: Context) -> DemoVideoPlayerView {
        let view = DemoVideoPlayerView()
        context.coordinator.configure(url: url, isActive: isActive, playbackProgress: $playbackProgress, in: view)
        return view
    }

    func updateUIView(_ uiView: DemoVideoPlayerView, context: Context) {
        context.coordinator.configure(url: url, isActive: isActive, playbackProgress: $playbackProgress, in: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var timeObserver: Any?
        private var playbackProgress: Binding<Double>?

        deinit {
            removeTimeObserver()
        }

        func configure(url: URL, isActive: Bool, playbackProgress: Binding<Double>, in view: DemoVideoPlayerView) {
            self.playbackProgress = playbackProgress

            if currentURL != url {
                currentURL = url
                playbackProgress.wrappedValue = 0
                removeTimeObserver()

                let item = AVPlayerItem(url: url)
                let queuePlayer = AVQueuePlayer()
                queuePlayer.actionAtItemEnd = .none
                looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
                player = queuePlayer
                view.playerLayer.player = queuePlayer
                addTimeObserver(to: queuePlayer)
            }

            updatePlayback(isActive: isActive)
        }

        private func updatePlayback(isActive: Bool) {
            guard let player else { return }
            player.isMuted = !isActive
            player.volume = isActive ? 1 : 0

            if isActive {
                configureAudioPlayback()
                player.play()
            } else {
                player.pause()
            }
        }

        private func addTimeObserver(to player: AVQueuePlayer) {
            let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                guard let self, let player, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else {
                    self?.playbackProgress?.wrappedValue = 0
                    return
                }
                let progress = min(max(time.seconds / duration, 0), 1)
                self.playbackProgress?.wrappedValue = progress
            }
        }

        private func removeTimeObserver() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
        }

        private func configureAudioPlayback() {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try? audioSession.setActive(true)
            #endif
        }
    }
}

private final class DemoVideoPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = UIColor(CSFDesign.deepSurface)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct RailActionLabel: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(CSFDesign.textPrimary)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(CSFDesign.textPrimary.opacity(0.18))
                }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(CSFDesign.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RailActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct FullUploadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(CSFDesign.textPrimary)
            .labelStyle(.titleAndIcon)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                CSFDesign.primary.opacity(configuration.isPressed ? 0.48 : 0.68),
                                CSFDesign.violet.opacity(configuration.isPressed ? 0.22 : 0.34)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                CSFDesign.textPrimary.opacity(0.55),
                                CSFDesign.primary.opacity(0.72),
                                CSFDesign.violet.opacity(0.42)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            }
            .shadow(color: CSFDesign.primary.opacity(configuration.isPressed ? 0.18 : 0.38), radius: 24, y: 12)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private final class ViewModelHolder: ObservableObject {
    @Published var viewModel: HomeViewModel?
}
