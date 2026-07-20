import ConcertSongFinderCore
import PhotosUI
import SwiftUI

protocol VideoImportService {
    func importMedia(_ items: [PhotosPickerItem]) async throws -> ConcertMediaImport
}
