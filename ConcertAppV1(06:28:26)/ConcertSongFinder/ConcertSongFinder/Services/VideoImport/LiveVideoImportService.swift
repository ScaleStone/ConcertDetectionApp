import AVFoundation
import ConcertSongFinderCore
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

final class LiveVideoImportService: VideoImportService {
    private let workingDirectory: URL

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func importMedia(_ items: [PhotosPickerItem]) async throws -> ConcertMediaImport {
        guard !items.isEmpty else { return ConcertMediaImport(videos: [], photos: []) }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        AppLog.importLog.info("Media import started itemCount=\(items.count, privacy: .public) workingDirectory=\(self.workingDirectory.lastPathComponent, privacy: .public)")

        var importedVideos: [ConcertVideo] = []
        var importedPhotos: [ConcertPhoto] = []
        var seenKeys: Set<String> = []

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let localIdentifier = item.itemIdentifier
            let dedupeKey = localIdentifier ?? "selection-\(index)"
            guard !seenKeys.contains(dedupeKey) else {
                AppLog.importLog.info("Skipping duplicate selected media index=\(index, privacy: .public) localIdentifierPresent=\((localIdentifier != nil), privacy: .public)")
                continue
            }
            seenKeys.insert(dedupeKey)
            AppLog.importLog.info("Processing selected media index=\(index, privacy: .public) localIdentifierPresent=\((localIdentifier != nil), privacy: .public) supportedTypes=\(item.supportedContentTypes.map(\.identifier).joined(separator: ","), privacy: .public)")

            if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                let photo = try await importPhoto(item, index: index, localIdentifier: localIdentifier)
                importedPhotos.append(photo)
                AppLog.importLog.info("Imported selected image index=\(index, privacy: .public) photoID=\(photo.id.uuidString, privacy: .public) file=\(photo.fileName, privacy: .public)")
                continue
            }

            guard let transferred = try await item.loadTransferable(type: PickedVideoFile.self) else {
                throw ConcertSongFinderError.videoImportCanceled
            }

            let stableID = UUID()
            let fileExtension = transferred.url.pathExtension.isEmpty ? "mov" : transferred.url.pathExtension
            let destination = workingDirectory
                .appendingPathComponent(stableID.uuidString, isDirectory: false)
                .appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: transferred.url, to: destination)

            let phAsset = localIdentifier.flatMap { identifier in
                PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            }
            AppLog.importLog.info("Import metadata lookup index=\(index, privacy: .public) localIdentifierPresent=\((localIdentifier != nil), privacy: .public) phAssetFound=\((phAsset != nil), privacy: .public)")
            let metadata = try await metadata(for: destination, phAsset: phAsset)
            AppLog.importLog.info("Import metadata resolved file=\(destination.lastPathComponent, privacy: .public) createdAt=\(metadata.createdAt.map { Formatting.timestamp.string(from: $0) } ?? "nil", privacy: .public) locationSource=\(metadata.locationSource, privacy: .public) duration=\(metadata.duration, privacy: .public)")

            importedVideos.append(
                ConcertVideo(
                    id: stableID,
                    localIdentifier: localIdentifier,
                    localURL: destination,
                    fileName: destination.lastPathComponent,
                    createdAt: metadata.createdAt,
                    duration: metadata.duration,
                    location: nil,
                    originalSelectionIndex: index,
                    analysisStatus: .metadataReady
                )
            )
            AppLog.importLog.info("Imported selected video index=\(index, privacy: .public) videoID=\(stableID.uuidString, privacy: .public) file=\(destination.lastPathComponent, privacy: .public)")
        }

        let sortedVideos = importedVideos.sorted {
                switch ($0.createdAt, $1.createdAt) {
                case let (.some(left), .some(right)) where left != right:
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return $0.originalSelectionIndex < $1.originalSelectionIndex
                }
            }
        let sortedPhotos = importedPhotos.sorted {
                switch ($0.createdAt, $1.createdAt) {
                case let (.some(left), .some(right)) where left != right:
                    return left < right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return $0.originalSelectionIndex < $1.originalSelectionIndex
                }
            }
        AppLog.importLog.info("Media import finished videoCount=\(sortedVideos.count, privacy: .public) photoCount=\(sortedPhotos.count, privacy: .public) videoOrder=\(sortedVideos.map(\.fileName).joined(separator: ","), privacy: .public) photoOrder=\(sortedPhotos.map(\.fileName).joined(separator: ","), privacy: .public)")
        return ConcertMediaImport(videos: sortedVideos, photos: sortedPhotos)
    }

    private func importPhoto(
        _ item: PhotosPickerItem,
        index: Int,
        localIdentifier: String?
    ) async throws -> ConcertPhoto {
        AppLog.importLog.info("Photo import starting index=\(index, privacy: .public) localIdentifierPresent=\((localIdentifier != nil), privacy: .public)")
        guard let transferred = try await item.loadTransferable(type: PickedImageFile.self) else {
            AppLog.importLog.error("Photo import canceled because transferable image was unavailable index=\(index, privacy: .public)")
            throw ConcertSongFinderError.videoImportCanceled
        }

        let stableID = UUID()
        let fileExtension = transferred.url.pathExtension.isEmpty ? "jpg" : transferred.url.pathExtension
        let destination = workingDirectory
            .appendingPathComponent(stableID.uuidString, isDirectory: false)
            .appendingPathExtension(fileExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: transferred.url, to: destination)

        let phAsset = localIdentifier.flatMap { identifier in
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }
        let metadata = try photoMetadata(for: destination, phAsset: phAsset)
        AppLog.importLog.info("Photo import metadata resolved file=\(destination.lastPathComponent, privacy: .public) createdAt=\(metadata.createdAt.map { Formatting.timestamp.string(from: $0) } ?? "nil", privacy: .public) locationSource=\(metadata.locationSource, privacy: .public)")

        return ConcertPhoto(
            id: stableID,
            localIdentifier: localIdentifier,
            localURL: destination,
            fileName: destination.lastPathComponent,
            createdAt: metadata.createdAt,
            location: nil,
            originalSelectionIndex: index
        )
    }

    private func sortedVideos(_ videos: [ConcertVideo]) -> [ConcertVideo] {
        videos.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.originalSelectionIndex < $1.originalSelectionIndex
            }
        }
    }

    private func metadata(for url: URL, phAsset: PHAsset?) async throws -> ImportedVideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ConcertSongFinderError.corruptedVideo
        }

        let phDate = phAsset?.creationDate
        let metadataDate = try await avAssetCreationDate(asset)
        let resourceDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        AppLog.importLog.info("Video GPS metadata intentionally ignored; timestamp is the only metadata used for concert lookup.")

        return ImportedVideoMetadata(
            createdAt: phDate ?? metadataDate ?? resourceDate,
            duration: duration,
            locationSource: "ignored"
        )
    }

    private func photoMetadata(for url: URL, phAsset: PHAsset?) throws -> ImportedPhotoMetadata {
        let phDate = phAsset?.creationDate
        AppLog.importLog.info("Photo metadata lookup phAssetFound=\((phAsset != nil), privacy: .public) phDatePresent=\((phDate != nil), privacy: .public)")
        let imageProperties = imageProperties(for: url)
        AppLog.importLog.info("Photo embedded metadata keyCount=\(imageProperties.count, privacy: .public)")
        let imageDate = imageDate(from: imageProperties)
        let resourceDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        AppLog.importLog.info("Photo GPS metadata intentionally ignored; timestamp is the only metadata used for classification.")

        return ImportedPhotoMetadata(
            createdAt: phDate ?? imageDate ?? resourceDate,
            locationSource: "ignored"
        )
    }

    private func imageProperties(for url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            AppLog.importLog.info("No readable image metadata found file=\(url.lastPathComponent, privacy: .public)")
            return [:]
        }
        return properties
    }

    private func imageDate(from properties: [CFString: Any]) -> Date? {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let candidates = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        ].compactMap { $0 }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return candidates.compactMap { formatter.date(from: $0) }.first
    }

    private func avAssetCreationDate(_ asset: AVURLAsset) async throws -> Date? {
        let metadata = try await asset.load(.metadata)
        
        var dateStrings: [String] = []
        for item in metadata {
            let isCreationDate = item.commonKey?.rawValue == "creationDate"
                || item.identifier?.rawValue.localizedCaseInsensitiveContains("creation") == true
            
            if isCreationDate, let value = try await item.load(.stringValue) {
                dateStrings.append(value)
            }
        }
        
        let formatters: [ISO8601DateFormatter] = {
            let standard = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [standard, fractional]
        }()
        for string in dateStrings {
            for formatter in formatters {
                if let date = formatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

}

private struct ImportedVideoMetadata {
    let createdAt: Date?
    let duration: TimeInterval
    let locationSource: String
}

private struct ImportedPhotoMetadata {
    let createdAt: Date?
    let locationSource: String
}

private struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            if FileManager.default.fileExists(atPath: temporary.path) {
                try FileManager.default.removeItem(at: temporary)
            }
            try FileManager.default.copyItem(at: received.file, to: temporary)
            return PickedVideoFile(url: temporary)
        }
    }
}

private struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension)
            if FileManager.default.fileExists(atPath: temporary.path) {
                try FileManager.default.removeItem(at: temporary)
            }
            try FileManager.default.copyItem(at: received.file, to: temporary)
            return PickedImageFile(url: temporary)
        }
    }
}
