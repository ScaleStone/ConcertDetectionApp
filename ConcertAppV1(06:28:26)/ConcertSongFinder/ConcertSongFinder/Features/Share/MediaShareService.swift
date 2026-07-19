import AVFoundation
import ConcertSongFinderCore
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Song/concert context attached to a shared media item.
struct MediaShareContext {
    let songTitle: String?
    let artist: String?
    let venue: String?
    let eventDate: Date?

    /// Caption burned onto the media, e.g. "♪ family ties — Baby Keem".
    var captionText: String? {
        guard let songTitle else { return nil }
        if let artist, !artist.isEmpty {
            return "♪ \(songTitle) — \(artist)"
        }
        return "♪ \(songTitle)"
    }

    /// Text item accompanying the share (used by Messages, Mail, etc.).
    var shareText: String {
        var parts: [String] = []
        if let songTitle {
            if let artist, !artist.isEmpty {
                parts.append("🎵 \(songTitle) — \(artist)")
            } else {
                parts.append("🎵 \(songTitle)")
            }
        } else if let artist, !artist.isEmpty {
            parts.append("🎵 \(artist)")
        }
        var detail: [String] = []
        if let venue, !venue.isEmpty { detail.append(venue) }
        if let eventDate { detail.append(Self.dateFormatter.string(from: eventDate)) }
        if !detail.isEmpty { parts.append(detail.joined(separator: " · ")) }
        return parts.joined(separator: "\n")
    }

    /// Sanitized filename stem, e.g. "Baby Keem - family ties".
    var fileNameStem: String {
        var stem: String
        switch (artist, songTitle) {
        case let (.some(artist), .some(song)):
            stem = "\(artist) - \(song)"
        case let (.none, .some(song)):
            stem = song
        case let (.some(artist), .none):
            stem = artist
        case (.none, .none):
            stem = "Concert"
        }
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        stem = stem.components(separatedBy: invalid).joined()
        return String(stem.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

enum MediaShareError: LocalizedError {
    case unreadableImage
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The photo could not be read for sharing."
        case .exportFailed: return "The video could not be prepared for sharing."
        }
    }
}

/// Prepares media for the system share sheet: tagged filename, embedded
/// metadata, and an optional caption overlay burned into the pixels so the
/// song name survives Instagram, TikTok, and other apps that strip metadata.
enum MediaShareService {
    private static var shareDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ConcertSongFinder-share", isDirectory: true)
    }

    static func cleanUpSharedFiles() {
        try? FileManager.default.removeItem(at: shareDirectory)
    }

    // MARK: - Photos

    static func preparePhoto(
        at sourceURL: URL,
        context: MediaShareContext,
        includeCaption: Bool
    ) throws -> URL {
        guard let image = UIImage(contentsOfFile: sourceURL.path) else {
            throw MediaShareError.unreadableImage
        }

        let finalImage: UIImage
        if includeCaption, let caption = context.captionText {
            finalImage = Self.drawCaption(caption, on: image)
        } else {
            finalImage = image
        }

        guard let jpegData = finalImage.jpegData(compressionQuality: 0.92) else {
            throw MediaShareError.unreadableImage
        }

        let destination = try makeDestinationURL(stem: context.fileNameStem, fileExtension: "jpg")
        try writeJPEG(jpegData, to: destination, context: context)
        return destination
    }

    private static func writeJPEG(_ data: Data, to url: URL, context: MediaShareContext) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageDestination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaShareError.unreadableImage
        }

        var properties: [CFString: Any] = [:]
        var iptc: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        if let title = context.songTitle {
            iptc[kCGImagePropertyIPTCObjectName] = title
            tiff[kCGImagePropertyTIFFImageDescription] = context.shareText.replacingOccurrences(of: "\n", with: " · ")
        }
        if let artist = context.artist {
            tiff[kCGImagePropertyTIFFArtist] = artist
        }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }

        CGImageDestinationAddImageFromSource(imageDestination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw MediaShareError.unreadableImage
        }
    }

    private static func drawCaption(_ caption: String, on image: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { rendererContext in
            image.draw(at: .zero)

            let fontSize = max(18, image.size.width * 0.032)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white
            ]
            let textSize = (caption as NSString).size(withAttributes: attributes)
            let horizontalPadding = fontSize * 0.7
            let verticalPadding = fontSize * 0.45
            let margin = fontSize * 0.9

            let pillSize = CGSize(
                width: min(textSize.width + horizontalPadding * 2, image.size.width - margin * 2),
                height: textSize.height + verticalPadding * 2
            )
            let pillOrigin = CGPoint(x: margin, y: image.size.height - pillSize.height - margin)
            let pillRect = CGRect(origin: pillOrigin, size: pillSize)

            let pill = UIBezierPath(roundedRect: pillRect, cornerRadius: pillSize.height / 2)
            UIColor.black.withAlphaComponent(0.55).setFill()
            pill.fill()

            (caption as NSString).draw(
                in: CGRect(
                    x: pillRect.minX + horizontalPadding,
                    y: pillRect.minY + verticalPadding,
                    width: pillRect.width - horizontalPadding * 2,
                    height: pillRect.height - verticalPadding * 2
                ),
                withAttributes: attributes
            )
        }
    }

    // MARK: - Videos

    static func prepareVideo(
        at sourceURL: URL,
        context: MediaShareContext,
        includeCaption: Bool
    ) async throws -> URL {
        if includeCaption, context.captionText != nil {
            return try await exportCaptionedVideo(at: sourceURL, context: context)
        }
        return try await exportPassthroughVideo(at: sourceURL, context: context)
    }

    /// Fast path: no caption means no re-encode; passthrough export writes
    /// the tagged filename + QuickTime metadata only.
    private static func exportPassthroughVideo(at sourceURL: URL, context: MediaShareContext) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let destination = try makeDestinationURL(stem: context.fileNameStem, fileExtension: "mov")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            // Fall back to a plain tagged-name copy.
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }
        session.metadata = shareMetadata(for: context)
        do {
            try await session.export(to: destination, as: .mov)
        } catch {
            AppLog.concertLibrary.error("Passthrough share export failed; copying original error=\(error.localizedDescription, privacy: .public)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    /// Caption path: re-encodes the video with the caption pill composited
    /// onto every frame so the song name survives social media uploads.
    private static func exportCaptionedVideo(at sourceURL: URL, context: MediaShareContext) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let caption = context.captionText,
              let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaShareError.exportFailed
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Normalize the track's preferred transform (portrait/rotated video)
        // into the render space.
        var transform = preferredTransform
        transform.tx -= min(transformedRect.minX, 0)
        transform.ty -= min(transformedRect.minY, 0)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        // Caption pill rendered via Core Animation onto every frame.
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(captionLayer(caption, renderSize: renderSize))
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaShareError.exportFailed
        }
        session.videoComposition = composition
        session.metadata = shareMetadata(for: context)

        let destination = try makeDestinationURL(stem: context.fileNameStem, fileExtension: "mov")
        do {
            try await session.export(to: destination, as: .mov)
        } catch {
            AppLog.concertLibrary.error("Captioned share export failed error=\(error.localizedDescription, privacy: .public)")
            throw MediaShareError.exportFailed
        }
        return destination
    }

    private static func captionLayer(_ caption: String, renderSize: CGSize) -> CALayer {
        let fontSize = max(18, renderSize.width * 0.032)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (caption as NSString).size(withAttributes: attributes)
        let horizontalPadding = fontSize * 0.7
        let verticalPadding = fontSize * 0.45
        let margin = fontSize * 0.9

        let pillSize = CGSize(
            width: min(textSize.width + horizontalPadding * 2, renderSize.width - margin * 2),
            height: textSize.height + verticalPadding * 2
        )

        let pillLayer = CALayer()
        // CALayer origin is bottom-left in video space; keep the pill at the
        // bottom-left corner with a margin.
        pillLayer.frame = CGRect(x: margin, y: margin, width: pillSize.width, height: pillSize.height)
        pillLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        pillLayer.cornerRadius = pillSize.height / 2
        pillLayer.masksToBounds = true

        let textLayer = CATextLayer()
        textLayer.string = NSAttributedString(string: caption, attributes: attributes)
        textLayer.frame = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: pillSize.width - horizontalPadding * 2,
            height: textSize.height
        )
        textLayer.contentsScale = 2
        textLayer.isWrapped = false
        textLayer.truncationMode = .end
        pillLayer.addSublayer(textLayer)
        return pillLayer
    }

    private static func shareMetadata(for context: MediaShareContext) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let title = context.songTitle {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            items.append(item)
        }
        if let artist = context.artist {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtist
            item.value = artist as NSString
            items.append(item)
        }
        let description = AVMutableMetadataItem()
        description.identifier = .commonIdentifierDescription
        description.value = context.shareText.replacingOccurrences(of: "\n", with: " · ") as NSString
        items.append(description)
        return items
    }

    private static func makeDestinationURL(stem: String, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        var destination = shareDirectory
            .appendingPathComponent(stem, isDirectory: false)
            .appendingPathExtension(fileExtension)
        // Avoid collisions from repeated shares of the same song.
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = shareDirectory
                .appendingPathComponent("\(stem) \(counter)", isDirectory: false)
                .appendingPathExtension(fileExtension)
            counter += 1
        }
        return destination
    }
}
