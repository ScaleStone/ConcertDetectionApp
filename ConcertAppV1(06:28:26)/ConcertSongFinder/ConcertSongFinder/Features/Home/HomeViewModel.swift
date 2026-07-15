import ConcertSongFinderCore
import Foundation
import Photos
import PhotosUI
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published private(set) var recentRecords: [AnalysisRecord] = []
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionState: PermissionState = .unknown

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() {
        permissionState = PermissionState(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        do {
            recentRecords = try environment.historyStore.loadRecords()
                .sorted { $0.updatedAt > $1.updatedAt }
            AppLog.importLog.info("Home loaded recent records count=\(self.recentRecords.count, privacy: .public) permission=\(String(describing: self.permissionState), privacy: .public)")
        } catch {
            errorMessage = "Could not load recent analyses."
            AppLog.importLog.error("Home failed to load recent records: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importSelectedItems() async -> ConcertMediaImport? {
        guard !selectedItems.isEmpty else { return nil }
        let selectedItemCount = selectedItems.count
        AppLog.importLog.info("Home import requested selectedItemCount=\(selectedItemCount, privacy: .public)")
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let mediaImport = try await environment.videoImportService.importMedia(selectedItems)
            selectedItems = []
            if mediaImport.isEmpty {
                errorMessage = "No media was imported."
                AppLog.importLog.error("Home import completed with empty result.")
                return nil
            }
            AppLog.importLog.info("Home import completed videoCount=\(mediaImport.videos.count, privacy: .public) photoCount=\(mediaImport.photos.count, privacy: .public)")
            return mediaImport
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            selectedItems = []
            AppLog.importLog.error("Home import failed selectedItemCount=\(selectedItemCount, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

enum PermissionState: Equatable {
    case unknown
    case available
    case limited
    case denied

    init(status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .available
        case .limited:
            self = .limited
        case .denied, .restricted:
            self = .denied
        case .notDetermined:
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }
}
