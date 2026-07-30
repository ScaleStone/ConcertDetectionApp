import ConcertSongFinderCore
import SwiftUI
import UIKit

/// "Post Ideas" section for the concert detail screen: opt-in AI suggestions
/// grouped into categories (Artist Feature, Unique Moments, Best Quality,
/// Photo Slideshow), sharing through the existing pipeline. Empty categories
/// are hidden.
///
/// Privacy: strictly consent-gated (off by default). No network request is
/// made before the user grants consent, and consent is revocable from the
/// section menu at any time.
struct PostIdeasSection: View {
    let concert: ConcertRecord

    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("postIdeasConsentGranted") private var consentGranted = false
    /// Testing: request per-candidate scores + reasoning from the model.
    @AppStorage("postIdeasShowScores") private var showScores = false
    @State private var showConsentSheet = false
    @State private var isLoading = false
    @State private var result: SuggestionService.Result?
    @State private var errorMessage: String?
    @State private var dismissedCandidateIDs: Set<String> = []
    @State private var shareRequest: MediaShareRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Picking your best moments…")
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.textPrimary.opacity(0.60))
                }
                .padding(.vertical, 8)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(CSFDesign.amber)
                    Button("Try Again") { requestIdeas() }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.vertical, 4)
            } else if let result {
                loadedContent(result)
            } else {
                Button {
                    if consentGranted {
                        requestIdeas()
                    } else {
                        showConsentSheet = true
                    }
                } label: {
                    Label("Get Post Ideas", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(CSFDesign.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal)
        .sheet(isPresented: $showConsentSheet) {
            PostIdeasConsentSheet {
                consentGranted = true
                requestIdeas()
            }
        }
        .sheet(item: $shareRequest) { ShareMediaSheet(request: $0) }
        .onChange(of: showScores) {
            // Re-run with/without scoring when the testing toggle flips
            // (cached results per mode make flipping back instant).
            if result != nil { requestIdeas() }
        }
    }

    @ViewBuilder
    private func loadedContent(_ result: SuggestionService.Result) -> some View {
        let visible = result.response.suggestions.filter { !dismissedCandidateIDs.contains($0.candidateId) }
        if visible.isEmpty {
            Text("All ideas dismissed. Tap Refresh in the ••• menu to see the same picks again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(SuggestionCategory.displayOrder, id: \.rawValue) { category in
                let entries = visible
                    .filter { $0.suggestionCategory == category }
                    .sorted { $0.rank < $1.rank }
                if !entries.isEmpty {
                    categoryHeader(category)
                    if category == .photoSlideshow {
                        SlideshowCard(
                            entries: entries,
                            candidatesByID: result.candidatesByID,
                            onShare: { shareSlideshow(entries: entries, result: result) },
                            onDismiss: { dismissSlideshow(entries: entries, result: result) }
                        )
                    } else {
                        ForEach(entries) { suggestion in
                            if let candidate = result.candidatesByID[suggestion.candidateId] {
                                PostIdeaCard(
                                    suggestion: suggestion,
                                    candidate: candidate,
                                    onShare: { share(suggestion: suggestion, candidate: candidate, result: result) },
                                    onDismiss: { dismissIdea(suggestion, result: result) }
                                )
                            }
                        }
                    }
                }
            }
        }
        if showScores {
            if let evaluations = result.response.evaluations {
                AIScoresPanel(
                    evaluations: evaluations,
                    pickedIDs: Set(result.response.suggestions.map(\.candidateId)),
                    candidatesByID: result.candidatesByID
                )
            } else {
                Text("Scores were not requested for this result. Tap Refresh to re-run with scoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryHeader(_ category: SuggestionCategory) -> some View {
        Label(category.displayName, systemImage: category.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var header: some View {
        HStack {
            Label("Post Ideas", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if consentGranted {
                Menu {
                    Button("Refresh") {
                        dismissedCandidateIDs = []
                        requestIdeas()
                    }
                    Toggle("Show AI Scores (Testing)", isOn: $showScores)
                    Button("Turn Off Post Ideas", role: .destructive) {
                        consentGranted = false
                        result = nil
                        errorMessage = nil
                        AppLog.postIdeas.info("Post ideas consent revoked")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(CSFDesign.textPrimary.opacity(0.60))
                }
                .accessibilityLabel("Post ideas options")
            }
        }
    }

    private func requestIdeas() {
        guard consentGranted, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let fetched = try await environment.postSuggestionService.suggestions(for: concert, includeScores: showScores)
                result = fetched
            } catch is CancellationError {
                // View went away; nothing to show.
            } catch let error as ConcertSongFinderError {
                errorMessage = friendlyMessage(for: error)
                AppLog.postIdeas.error("Post ideas failed concert=\(concert.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            } catch {
                errorMessage = "Post ideas aren't available right now."
                AppLog.postIdeas.error("Post ideas failed concert=\(concert.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            isLoading = false
        }
    }

    private func friendlyMessage(for error: ConcertSongFinderError) -> String {
        switch error {
        case .rateLimited:
            return "Post ideas are taking a break — the daily limit was reached. Try again tomorrow."
        case .backendUnavailable:
            return "Post ideas are temporarily unavailable. Your concerts are unaffected."
        default:
            return "Post ideas aren't available right now. Check your connection and try again."
        }
    }

    private func shareContext(songTitle: String?, artist: String?) -> MediaShareContext {
        MediaShareContext(
            songTitle: songTitle,
            artist: artist ?? concert.selectedSetlist?.artistName ?? concert.selectedConcert?.artistName,
            venue: concert.selectedSetlist?.venueName ?? concert.selectedConcert?.venueName,
            eventDate: concert.concertDate
        )
    }

    private func share(suggestion: PostSuggestionDTO, candidate: SuggestionCandidateBuilder.BuiltCandidate, result: SuggestionService.Result) {
        environment.postSuggestionService.logOutcome("used", suggestion: suggestion, response: result.response, concert: concert)
        let media: MediaShareRequest.Media
        switch candidate.item.media {
        case .video(let video, _): media = .video(video)
        case .photo(let photo): media = .photo(photo)
        }
        shareRequest = MediaShareRequest(
            media: media,
            context: shareContext(songTitle: candidate.item.songTitle, artist: candidate.item.songArtist),
            clipRange: suggestion.clipRange
        )
    }

    private func shareSlideshow(entries: [PostSuggestionDTO], result: SuggestionService.Result) {
        let photos: [ConcertPhoto] = entries.compactMap { entry in
            guard case .photo(let photo) = result.candidatesByID[entry.candidateId]?.item.media else { return nil }
            return photo
        }
        guard !photos.isEmpty else { return }
        for entry in entries {
            environment.postSuggestionService.logOutcome("used", suggestion: entry, response: result.response, concert: concert)
        }
        shareRequest = MediaShareRequest(
            media: .slideshow(photos),
            context: shareContext(songTitle: nil, artist: nil),
            clipRange: nil
        )
    }

    private func dismissIdea(_ suggestion: PostSuggestionDTO, result: SuggestionService.Result) {
        environment.postSuggestionService.logOutcome("dismissed", suggestion: suggestion, response: result.response, concert: concert)
        withAnimation { _ = dismissedCandidateIDs.insert(suggestion.candidateId) }
    }

    private func dismissSlideshow(entries: [PostSuggestionDTO], result: SuggestionService.Result) {
        for entry in entries {
            environment.postSuggestionService.logOutcome("dismissed", suggestion: entry, response: result.response, concert: concert)
        }
        withAnimation { dismissedCandidateIDs.formUnion(entries.map(\.candidateId)) }
    }
}

// MARK: - AI Scores (testing)

/// Testing panel: the model's score, best-fit category, and reasoning for
/// EVERY candidate it considered, sorted by score, with the actual picks
/// highlighted. Visible only when "Show AI Scores (Testing)" is enabled.
private struct AIScoresPanel: View {
    let evaluations: [CandidateEvaluationDTO]
    let pickedIDs: Set<String>
    let candidatesByID: [String: SuggestionCandidateBuilder.BuiltCandidate]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(evaluations) { evaluation in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(evaluation.score)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .frame(width: 40, height: 28)
                            .background(scoreColor(evaluation.score).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(scoreColor(evaluation.score))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(label(for: evaluation.candidateId))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if let category = evaluation.category.flatMap(SuggestionCategory.init(rawValue:)) {
                                    Text(category.displayName)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary.opacity(0.6), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                if pickedIDs.contains(evaluation.candidateId) {
                                    Text("PICKED")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(evaluation.reasoning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("AI Scores (Testing) — \(evaluations.count) candidates", systemImage: "chart.bar.doc.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(for candidateId: String) -> String {
        guard let candidate = candidatesByID[candidateId] else { return candidateId }
        let kind = candidate.dto.kind == "video" ? "🎬" : "📷"
        return "\(kind) \(candidate.item.displayLabel)"
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 45..<75: return .orange
        default: return .red
        }
    }
}

// MARK: - Video idea card

private struct PostIdeaCard: View {
    let suggestion: PostSuggestionDTO
    let candidate: SuggestionCandidateBuilder.BuiltCandidate
    let onShare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(candidate.item.displayLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel("Dismiss this idea")
                    }
                    if let clipRange = suggestion.clipRange {
                        Label(
                            "Best part: \(Formatting.duration(clipRange.lowerBound))–\(Formatting.duration(clipRange.upperBound))",
                            systemImage: "scissors"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    }
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(CSFDesign.textPrimary.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.caption)
                    .font(.caption)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestion.hashtags.isEmpty {
                    Text(suggestion.hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button {
                    UIPasteboard.general.string = captionForClipboard
                } label: {
                    Label("Copy Caption", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(CSFDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CSFDesign.line)
        }
        .accessibilityElement(children: .contain)
    }

    private var captionForClipboard: String {
        let tags = suggestion.hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " ")
        return tags.isEmpty ? suggestion.caption : "\(suggestion.caption)\n\(tags)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.thinMaterial)
            if let image = candidate.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: candidate.dto.kind == "video" ? "play.rectangle" : "photo")
                    .foregroundStyle(CSFDesign.textPrimary.opacity(0.60))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if candidate.dto.kind == "video" {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(CSFDesign.textPrimary)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(3)
            }
        }
    }
}

// MARK: - Photo slideshow card

/// One card for the whole slideshow: swipeable photo strip, the rank-1
/// caption, and a single share that exports a generated slideshow video.
private struct SlideshowCard: View {
    let entries: [PostSuggestionDTO]
    let candidatesByID: [String: SuggestionCandidateBuilder.BuiltCandidate]
    let onShare: () -> Void
    let onDismiss: () -> Void

    private var leadEntry: PostSuggestionDTO? { entries.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(entries.count) photos, ~2s each")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Dismiss the slideshow")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.thinMaterial)
                            if let image = candidatesByID[entry.candidateId]?.previewImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            Text("\(entry.rank)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(3)
                        }
                    }
                }
            }

            if let lead = leadEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lead.caption)
                        .font(.caption)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                    if !lead.hashtags.isEmpty {
                        Text(lead.hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if let lead = leadEntry {
                    Button {
                        let tags = lead.hashtags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " ")
                        UIPasteboard.general.string = tags.isEmpty ? lead.caption : "\(lead.caption)\n\(tags)"
                    } label: {
                        Label("Copy Caption", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(action: onShare) {
                    Label("Share Slideshow", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Consent

/// Plain-language consent sheet (task 0.2). Nothing is sent anywhere until
/// the user taps Allow, and the choice can be reversed from the section menu.
struct PostIdeasConsentSheet: View {
    let onAllow: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("How Post Ideas works", systemImage: "sparkles")
                        .font(.title3.weight(.semibold))

                    explanationRow(
                        icon: "photo.on.rectangle",
                        title: "A few small still frames leave your device",
                        detail: "Up to 4 low-resolution snapshots per clip, plus song titles and the concert name, are sent to our server and an AI service to pick your best moments."
                    )
                    explanationRow(
                        icon: "video.slash",
                        title: "Never your videos or audio",
                        detail: "Full videos, audio, live photos, and your photo library never leave your device."
                    )
                    explanationRow(
                        icon: "location.slash",
                        title: "No location or personal info",
                        detail: "Snapshots are stripped of all metadata before sending. Nothing is stored on our server after your ideas are generated."
                    )
                    explanationRow(
                        icon: "hand.raised",
                        title: "Off by default, always reversible",
                        detail: "Post Ideas only runs when you ask for it, and you can turn it off anytime from the ••• menu."
                    )
                }
                .padding()
            }
            .csfPageChrome()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        AppLog.postIdeas.info("Post ideas consent granted")
                        dismiss()
                        onAllow()
                    } label: {
                        Text("Allow Post Ideas")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Not Now") { dismiss() }
                        .font(.subheadline)
                }
                .padding()
                .background(CSFDesign.surface)
            }
            .navigationTitle("Post Ideas")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func explanationRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(CSFDesign.textPrimary.opacity(0.60))
            }
        }
    }
}
