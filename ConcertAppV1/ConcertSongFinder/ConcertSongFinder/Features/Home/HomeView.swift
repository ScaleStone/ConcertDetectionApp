import ConcertSongFinderCore
import PhotosUI
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModelHolder = ViewModelHolder()
    let onImported: (ConcertMediaImport) -> Void

    var body: some View {
        Group {
            if let viewModel = viewModelHolder.viewModel {
                HomeContentView(viewModel: viewModel, onImported: onImported)
            } else {
                ProgressView()
                    .task {
                        viewModelHolder.viewModel = HomeViewModel(environment: environment)
                        viewModelHolder.viewModel?.load()
                    }
            }
        }
        .navigationTitle("ConcertSongFinder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct HomeContentView: View {
    @ObservedObject var viewModel: HomeViewModel
    let onImported: (ConcertMediaImport) -> Void

    var body: some View {
        CSFScreen {
            hero

            if viewModel.isImporting {
                importProgress
            }

            if let error = viewModel.errorMessage {
                messageCard(icon: "exclamationmark.triangle.fill", title: "Import needs attention", message: error, tint: CSFDesign.amber)
            }

            permissionCard
            workflowCard
        }
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

    private var hero: some View {
        let pickerTitle = viewModel.isImporting ? "Importing Media" : "Select Concert Media"

        return CSFCard(padding: 18) {
            CSFHeroLead(
                icon: "waveform.badge.magnifyingglass",
                title: "Build a setlist from your concert videos.",
                subtitle: "Import clips and photos, then let ShazamKit, timeline smoothing, and fallback matching sort the night into songs, transitions, and unknown ranges."
            )

            CSFMetricGrid {
                CSFMetricTile(title: "Video Windows", value: "Overlap", icon: "rectangle.split.3x1", tint: CSFDesign.blue)
                CSFMetricTile(title: "Timeline", value: "Merged", icon: "timeline.selection", tint: CSFDesign.primary)
                CSFMetricTile(title: "Fallback", value: "Lyrics", icon: "text.quote", tint: CSFDesign.pink)
            }

            PhotosPicker(
                selection: Binding(
                    get: { viewModel.selectedItems },
                    set: { viewModel.selectedItems = $0 }
                ),
                maxSelectionCount: 0,
                matching: .any(of: [.videos, .images])
            ) {
                Label(pickerTitle, systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(CSFPrimaryButtonStyle())
            .disabled(viewModel.isImporting)
        }
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
    private var permissionCard: some View {
        switch viewModel.permissionState {
        case .denied:
            messageCard(
                icon: "lock.fill",
                title: "Photo access is denied",
                message: "The picker may still provide selected items where iOS allows it, or you can update access in Settings.",
                tint: CSFDesign.amber
            )
        case .limited:
            messageCard(
                icon: "photo.badge.checkmark",
                title: "Limited library access",
                message: "Selected media will import when available. Full library access can improve timestamp and location ordering.",
                tint: CSFDesign.blue
            )
        default:
            EmptyView()
        }
    }

    private var workflowCard: some View {
        CSFCard {
            CSFSectionHeader(title: "Analysis Pipeline", subtitle: "Designed for messy concert audio and repeated songs.")
            VStack(spacing: 10) {
                workflowRow(icon: "calendar.badge.clock", title: "Order the night", detail: "Creation dates, locations, file metadata, and selection order are reconciled.")
                workflowRow(icon: "waveform", title: "Identify windows", detail: "Audio is extracted into temporary files and scanned through overlapping ShazamKit ranges.")
                workflowRow(icon: "arrow.triangle.2.circlepath", title: "Separate concerts", detail: "Timestamp clusters, raw matches, unknown sections, speech, and transitions stay available for correction.")
            }
        }
    }

    private func workflowRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(CSFDesign.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CSFDesign.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(CSFDesign.textPrimary.opacity(0.58))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageCard(icon: String, title: String, message: String, tint: Color) -> some View {
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

private final class ViewModelHolder: ObservableObject {
    @Published var viewModel: HomeViewModel?
}
