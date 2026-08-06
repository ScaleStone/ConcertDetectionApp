import ConcertSongFinderCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var uploadRoute: UploadRoute = .upload
    @State private var selectedTab: AppTab = AppTab.initial
    @State private var uploadPickerRequest = 0

    var body: some View {
        ZStack {
            CSFDesign.pageBackground.ignoresSafeArea()

            currentTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomNavigationGradient
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            FloatingTabBar(selectedTab: $selectedTab) {
                uploadRoute = .upload
                uploadPickerRequest += 1
            }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard)
        }
        .tint(CSFDesign.primary)
        .background(CSFDesign.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var bottomNavigationGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.16),
                .init(color: CSFDesign.accentMud.opacity(0.08), location: 0.38),
                .init(color: CSFDesign.pageBackground.opacity(0.34), location: 0.58),
                .init(color: CSFDesign.pageBackground.opacity(0.74), location: 0.82),
                .init(color: CSFDesign.pageBackground.opacity(0.94), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 224)
        .blur(radius: 8)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private var currentTabView: some View {
        switch selectedTab {
        case .library:
            NavigationStack {
                MyConcertsView()
            }
        case .clips:
            NavigationStack {
                SongClipsView()
            }
        case .upload:
            NavigationStack {
                uploadFlow
            }
        case .analysis:
            NavigationStack {
                AnalysisDashboardView()
            }
        case .profile:
            NavigationStack {
                ProfileView()
            }
        }
    }

    @ViewBuilder
    private var uploadFlow: some View {
        switch uploadRoute {
        case .upload:
            HomeView(isActive: selectedTab == .upload, openUploadPickerRequest: uploadPickerRequest) { mediaImport in
                // Analysis starts immediately after import; concert
                // assignment is fully automatic (identification first,
                // timestamp fallback otherwise) at persistence time.
                let record = AnalysisRecord(videos: mediaImport.videos, photos: mediaImport.photos)
                AppLog.importLog.info("RootView starting automatic analysis record=\(record.id.uuidString, privacy: .public) videos=\(mediaImport.videos.count, privacy: .public) photos=\(mediaImport.photos.count, privacy: .public)")
                uploadRoute = .analysis(record)
            }
        case .analysis(let record):
            AnalysisView(record: record) { completedRecord in
                persistCompletedConcert(completedRecord)
                uploadRoute = .results(completedRecord)
            } onCancel: { partialRecord in
                persistCompletedConcert(partialRecord)
                uploadRoute = .results(partialRecord)
            }
        case .results(let record):
            ResultsView(record: record) {
                AppLog.concertLibrary.info("RootView leaving results for record=\(record.id.uuidString, privacy: .public)")
                uploadRoute = .upload
            }
        }
    }

    private func persistCompletedConcert(_ record: AnalysisRecord) {
        do {
            // Fully automatic assignment: each timestamp cluster merges into
            // an existing concert (by identity, artist+day, or same-evening
            // timestamps) or becomes a new concert.
            let existingConcerts = try environment.concertLibraryStore.loadConcerts()
            for subRecord in record.perClusterAnalysisRecords() {
                let existing = ConcertRecord.findMatch(for: subRecord, in: existingConcerts)
                let concert = existing?.merged(with: subRecord) ?? ConcertRecord.newConcert(from: subRecord)
                try environment.concertLibraryStore.upsertConcert(concert)
                AppLog.concertLibrary.info("RootView persisted concert=\(concert.id.uuidString, privacy: .public) record=\(record.id.uuidString, privacy: .public) title=\(concert.displayTitle, privacy: .public) videos=\(concert.videos.count, privacy: .public) photos=\(concert.photos.count, privacy: .public)")
            }
        } catch {
            AppLog.concertLibrary.error("RootView failed to persist completed concert record=\(record.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum UploadRoute {
    case upload
    case analysis(AnalysisRecord)
    case results(AnalysisRecord)
}

private enum AppTab: Hashable, CaseIterable {
    case library
    case upload
    case clips
    case analysis
    case profile

    var title: String {
        switch self {
        case .library: "Library"
        case .clips: "Clips"
        case .upload: "Upload"
        case .analysis: "Analysis"
        case .profile: "Profile"
        }
    }

    var icon: String {
        switch self {
        case .library: "house"
        case .clips: "music.note.list"
        case .upload: "plus"
        case .analysis: "chart.bar.fill"
        case .profile: "person.crop.circle"
        }
    }

    static var initial: AppTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CSFInitialTab"),
              arguments.indices.contains(index + 1) else {
            return .library
        }
        switch arguments[index + 1].lowercased() {
        case "upload": return .upload
        case "clips": return .clips
        case "analysis": return .analysis
        case "profile": return .profile
        default: return .library
        }
    }
}

private struct FloatingTabBar: View {
    @Binding var selectedTab: AppTab
    let onUploadSelectedAgain: () -> Void
    @Namespace private var selectionNamespace

    private let tabs: [AppTab] = [.library, .clips, .upload, .analysis, .profile]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        if tab == .upload {
                            selectedTab = .upload
                            onUploadSelectedAgain()
                        } else {
                            selectedTab = tab
                        }
                    }
                } label: {
                    tabIcon(for: tab)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(height: 48)
        .background {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            CSFDesign.raisedSurface.opacity(0.80),
                            CSFDesign.surface.opacity(0.92),
                            CSFDesign.pageBackground.opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .fill(
                            RadialGradient(
                                colors: [
                                    CSFDesign.accentAcid.opacity(0.14),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 8,
                                endRadius: 210
                            )
                        )
                }
                .overlay {
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    CSFDesign.accentAcid.opacity(0.28),
                                    CSFDesign.border.opacity(0.70),
                                    CSFDesign.pageBackground.opacity(0.90)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
        }
    }

    @ViewBuilder
    private func tabIcon(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        ZStack {
            if isSelected {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                CSFDesign.accentMud.opacity(0.95),
                                CSFDesign.raisedSurface.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: tab == .upload ? 66 : 58, height: 36)
                    .matchedGeometryEffect(id: "selectedTab", in: selectionNamespace)
            }

            Image(systemName: tab.icon)
                .font(.system(size: tab == .upload ? 20 : 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? CSFDesign.primary : CSFDesign.textPrimary)

            if tab == .clips {
                Circle()
                    .fill(CSFDesign.primary)
                    .frame(width: 5, height: 5)
                    .offset(x: 17, y: 13)
                    .opacity(isSelected ? 1 : 0.88)
            }
        }
        .frame(width: tab == .upload ? 66 : 54, height: 38)
        .contentShape(Rectangle())
    }
}
