import AVFoundation
import ConcertSongFinderCore
import Foundation
import ShazamKit

final class ShazamMusicRecognitionService: MusicRecognitionService {
    func recognize(
        audio: PreparedAudio,
        configuration: RecognitionConfiguration
    ) async throws -> [RawRecognitionMatch] {
        let windows = RecognitionWindowPlanner.windows(duration: audio.duration, configuration: configuration)
        AppLog.analysis.info("Shazam diagnostic recognize audioURL=\(audio.audioURL.lastPathComponent, privacy: .public) duration=\(audio.duration, privacy: .public) sampleRate=\(audio.sampleRate, privacy: .public) channels=\(audio.channelCount, privacy: .public) configWindow=\(configuration.windowLength, privacy: .public) configStep=\(configuration.stepSize, privacy: .public) windowCount=\(windows.count, privacy: .public)")
        guard !windows.isEmpty else { return [] }

        var matches: [RawRecognitionMatch] = []
        for window in windows {
            try Task.checkCancellation()
            if let match = try await recognizeWindow(audio: audio, window: window, configuration: configuration) {
                matches.append(match)
            }
        }
        AppLog.analysis.info("Shazam diagnostic recognize finished totalMatches=\(matches.count, privacy: .public)")
        return matches
    }

    private func recognizeWindow(
        audio: PreparedAudio,
        window: RecognitionWindow,
        configuration: RecognitionConfiguration
    ) async throws -> RawRecognitionMatch? {
        let requestedDuration = window.end - window.start
        AppLog.analysis.info("Shazam diagnostic window start=\(window.start, privacy: .public) end=\(window.end, privacy: .public) requestedDuration=\(requestedDuration, privacy: .public)")

        let signature = try signature(for: audio.audioURL, window: window)
        AppLog.analysis.info("Shazam diagnostic signature ready window=\(window.start, privacy: .public)-\(window.end, privacy: .public) signatureDuration=\(signature.duration, privacy: .public) dataBytes=\(signature.dataRepresentation.count, privacy: .public)")

        let session = SHSession()
        let delegate = SignatureMatchDelegate(window: window)
        session.delegate = delegate
        do {
            let match = try await delegate.match(signature: signature, using: session)
            AppLog.analysis.info("Shazam diagnostic didFind window=\(window.start, privacy: .public)-\(window.end, privacy: .public) mediaItemCount=\(match.mediaItems.count, privacy: .public)")
            guard let mediaItem = match.mediaItems.first else { return nil }
            let title = mediaItem.title ?? "Unknown Title"
            let artist = mediaItem.artist ?? "Unknown Artist"
            let isrc = mediaItem.isrc
            let stableID = isrc ?? mediaItem.shazamID ?? TextNormalizer.normalizedSongKey(title: title, artist: artist)
            AppLog.analysis.info("Shazam diagnostic selectedMatch title=\(title, privacy: .public) artist=\(artist, privacy: .public) isrc=\(isrc ?? "", privacy: .public) shazamID=\(mediaItem.shazamID ?? "", privacy: .public) matchOffset=\(mediaItem.matchOffset, privacy: .public)")
            let song = SongIdentity(
                id: stableID,
                title: title,
                artist: artist,
                album: nil,
                isrc: isrc
            )
            return RawRecognitionMatch(
                windowStart: window.start,
                windowEnd: window.end,
                song: song,
                matchOffset: mediaItem.matchOffset,
                providerIdentifier: "shazam",
                metadata: [
                    "shazamID": mediaItem.shazamID ?? "",
                    "appleMusicID": mediaItem.appleMusicID ?? "",
                    "webURL": mediaItem.webURL?.absoluteString ?? ""
                ].filter { !$0.value.isEmpty },
                processingVersion: configuration.processingVersion,
                strength: 1
            )
        } catch {
            AppLog.analysis.error("Shazam diagnostic noMatchOrError window=\(window.start, privacy: .public)-\(window.end, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func signature(for audioURL: URL, window: RecognitionWindow) throws -> SHSignature {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let signatureFormat = try Self.signatureFormat(for: format)
        let converter = AVAudioConverter(from: format, to: signatureFormat)
        let startFrame = AVAudioFramePosition(window.start * sampleRate)
        let endFrame = min(file.length, AVAudioFramePosition(window.end * sampleRate))
        AppLog.analysis.info("Shazam diagnostic fileRead url=\(audioURL.lastPathComponent, privacy: .public) fileFrames=\(file.length, privacy: .public) formatSampleRate=\(sampleRate, privacy: .public) formatChannels=\(format.channelCount, privacy: .public) commonFormat=\(format.commonFormat.rawValue, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public) signatureSampleRate=\(signatureFormat.sampleRate, privacy: .public) signatureChannels=\(signatureFormat.channelCount, privacy: .public) startFrame=\(startFrame, privacy: .public) endFrame=\(endFrame, privacy: .public)")
        guard endFrame > startFrame else {
            throw ConcertSongFinderError.unrecognizableAudio
        }

        file.framePosition = startFrame
        let generator = SHSignatureGenerator()
        let chunkFrameCount: AVAudioFrameCount = 4096
        var currentFrame = startFrame
        var readIterations = 0
        var appendedFrames: AVAudioFramePosition = 0

        while currentFrame < endFrame {
            let remaining = AVAudioFrameCount(min(Int64(chunkFrameCount), endFrame - currentFrame))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else {
                throw ConcertSongFinderError.unrecognizableAudio
            }
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }

            let signatureBuffer = try Self.convertForSignature(
                buffer,
                using: converter,
                sourceSampleRate: sampleRate,
                signatureFormat: signatureFormat
            )
            let audioTime = AVAudioTime(sampleTime: appendedFrames, atRate: signatureFormat.sampleRate)
            try generator.append(signatureBuffer, at: audioTime)
            currentFrame += AVAudioFramePosition(buffer.frameLength)
            appendedFrames += AVAudioFramePosition(signatureBuffer.frameLength)
            readIterations += 1
        }

        let appendedDuration = Double(appendedFrames) / signatureFormat.sampleRate
        AppLog.analysis.info("Shazam diagnostic signatureInput window=\(window.start, privacy: .public)-\(window.end, privacy: .public) readIterations=\(readIterations, privacy: .public) appendedFrames=\(appendedFrames, privacy: .public) appendedDuration=\(appendedDuration, privacy: .public) finalFrame=\(currentFrame, privacy: .public)")
        return generator.signature()
    }

    private static func signatureFormat(for sourceFormat: AVAudioFormat) throws -> AVAudioFormat {
        let supportedSampleRates: [Double] = [48_000, 44_100, 32_000, 16_000]
        let targetSampleRate = supportedSampleRates.contains(sourceFormat.sampleRate)
            ? sourceFormat.sampleRate
            : 44_100
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ConcertSongFinderError.unrecognizableAudio
        }
        return format
    }

    private static func convertForSignature(
        _ sourceBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        sourceSampleRate: Double,
        signatureFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter else {
            return sourceBuffer
        }

        let sampleRateRatio = signatureFormat.sampleRate / sourceSampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * sampleRateRatio)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: signatureFormat, frameCapacity: outputCapacity) else {
            throw ConcertSongFinderError.unrecognizableAudio
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            throw ConcertSongFinderError.unrecognizableAudio
        }

        return outputBuffer
    }
}

private final class SignatureMatchDelegate: NSObject, SHSessionDelegate {
    private var continuation: CheckedContinuation<SHMatch, Error>?
    private let window: RecognitionWindow

    init(window: RecognitionWindow) {
        self.window = window
    }

    func match(signature: SHSignature, using session: SHSession) async throws -> SHMatch {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            AppLog.analysis.info("Shazam diagnostic delegate submitting signature window=\(self.window.start, privacy: .public)-\(self.window.end, privacy: .public) signatureDuration=\(signature.duration, privacy: .public)")
            session.match(signature)
        }
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        AppLog.analysis.info("Shazam diagnostic delegate didFind window=\(self.window.start, privacy: .public)-\(self.window.end, privacy: .public) mediaItemCount=\(match.mediaItems.count, privacy: .public)")
        continuation?.resume(returning: match)
        continuation = nil
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        AppLog.analysis.error("Shazam diagnostic delegate didNotFind window=\(self.window.start, privacy: .public)-\(self.window.end, privacy: .public) signatureDuration=\(signature.duration, privacy: .public) error=\(String(describing: error), privacy: .public)")
        continuation?.resume(throwing: error ?? ConcertSongFinderError.shazamNoMatch)
        continuation = nil
    }
}
