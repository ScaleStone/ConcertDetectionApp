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
        .navigationTitle("Upload")
    }
}

private struct HomeContentView: View {
    @ObservedObject var viewModel: HomeViewModel
    let onImported: (ConcertMediaImport) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Identify songs in concert videos and place photos on the song timeline.")
                        .font(.headline)
                    PhotosPicker(
                        selection: Binding(
                            get: { viewModel.selectedItems },
                            set: { viewModel.selectedItems = $0 }
                        ),
                        maxSelectionCount: 0,
                        matching: .any(of: [.videos, .images])
                    ) {
                        Label("Select Concert Media", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isImporting)
                }
                .padding(.vertical, 8)
            }

            if viewModel.isImporting {
                Section {
                    HStack {
                        ProgressView()
                        Text("Importing selected media...")
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            switch viewModel.permissionState {
            case .denied:
                Section("Permission") {
                    Text("Photo access is denied. You can still use the picker for selected items where iOS allows it, or update access in Settings.")
                }
            case .limited:
                Section("Permission") {
                    Text("Photo access is limited. Selected media will still import when available.")
                }
            default:
                EmptyView()
            }
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
}

private final class ViewModelHolder: ObservableObject {
    @Published var viewModel: HomeViewModel?
}
