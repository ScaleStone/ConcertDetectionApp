import ConcertSongFinderCore
import SwiftUI
import UIKit

/// A share request from the concert library: one media item plus its song
/// and concert context.
struct MediaShareRequest: Identifiable {
    enum Media {
        case video(ConcertVideo)
        case photo(ConcertPhoto)
    }

    let id = UUID()
    let media: Media
    let context: MediaShareContext

    var isVideo: Bool {
        if case .video = media { return true }
        return false
    }
}

/// Sheet flow: caption toggle → prepare (metadata + optional burn-in) →
/// system share sheet. The media is passed as a file URL, which is what
/// Instagram and other social apps accept from the share sheet.
struct ShareMediaSheet: View {
    let request: MediaShareRequest
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareIncludeCaption") private var includeCaption = true
    @State private var isPreparing = false
    @State private var preparedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preparedURL {
                    ActivityView(items: activityItems(for: preparedURL)) {
                        dismiss()
                    }
                    .ignoresSafeArea()
                } else {
                    Form {
                        Section {
                            LabeledContent("Song", value: request.context.songTitle ?? "Not identified")
                            if let artist = request.context.artist {
                                LabeledContent("Artist", value: artist)
                            }
                        }
                        if request.context.captionText != nil {
                            Section {
                                Toggle("Include song caption", isOn: $includeCaption)
                            } footer: {
                                Text(captionFooter)
                            }
                        }
                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Section {
                            Button {
                                prepare()
                            } label: {
                                if isPreparing {
                                    HStack {
                                        ProgressView()
                                        Text(request.isVideo && includeCaption && request.context.captionText != nil
                                             ? "Adding caption to video…"
                                             : "Preparing…")
                                    }
                                } else {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .disabled(isPreparing)
                        }
                    }
                    .navigationTitle("Share")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
            }
        }
    }

    private var captionFooter: String {
        if request.isVideo {
            return "Burns the song name onto the video so it stays visible on Instagram and other apps. Adding the caption re-encodes the video, which can take a moment."
        }
        return "Draws the song name onto the photo so it stays visible on Instagram and other apps."
    }

    private func activityItems(for url: URL) -> [Any] {
        // The file URL comes first so media-only apps (Instagram, TikTok)
        // appear in the sheet; the text rides along for apps that accept it.
        [url, request.context.shareText]
    }

    private func prepare() {
        isPreparing = true
        errorMessage = nil
        let includeCaption = includeCaption
        Task {
            do {
                let url: URL
                switch request.media {
                case .video(let video):
                    url = try await MediaShareService.prepareVideo(
                        at: video.localURL,
                        context: request.context,
                        includeCaption: includeCaption
                    )
                case .photo(let photo):
                    url = try MediaShareService.preparePhoto(
                        at: photo.localURL,
                        context: request.context,
                        includeCaption: includeCaption
                    )
                }
                await MainActor.run {
                    preparedURL = url
                    isPreparing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isPreparing = false
                }
            }
        }
    }
}

/// UIActivityViewController wrapper; completion fires when the user finishes
/// or cancels the share so the sheet can dismiss and temp files get cleaned.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
