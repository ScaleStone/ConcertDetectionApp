import ConcertSongFinderCore
import AVFoundation
import Foundation
import Speech

final class AppleSpeechTranscriptionService: SpeechTranscriptionService {
    func transcribe(
        audioURL: URL,
        timeRange: Range<TimeInterval>,
        locale: Locale?
    ) async throws -> [TranscriptAlternative] {
        let authorization = await requestAuthorization()
        guard authorization == .authorized else {
            throw ConcertSongFinderError.speechPermissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale ?? Locale.current), recognizer.isAvailable else {
            throw ConcertSongFinderError.speechRecognizerUnavailable
        }

        let clippedAudioURL = try await exportAudioClip(audioURL: audioURL, timeRange: timeRange)
        defer {
            if clippedAudioURL != audioURL {
                try? FileManager.default.removeItem(at: clippedAudioURL)
            }
        }

        let request = SFSpeechURLRecognitionRequest(url: clippedAudioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal, !didResume else { return }
                didResume = true
                let best = result.bestTranscription
                var alternatives: [TranscriptAlternative] = [
                    TranscriptAlternative(
                        text: best.formattedString,
                        confidence: best.segments.map(\.confidence).average,
                        startTime: timeRange.lowerBound,
                        endTime: timeRange.upperBound,
                        languageCode: recognizer.locale.identifier,
                        wordConfidences: best.wordConfidences
                    )
                ]

                for transcription in result.transcriptions.dropFirst().prefix(4) {
                    alternatives.append(
                        TranscriptAlternative(
                            text: transcription.formattedString,
                            confidence: transcription.segments.map(\.confidence).average,
                            startTime: timeRange.lowerBound,
                            endTime: timeRange.upperBound,
                            languageCode: recognizer.locale.identifier,
                            wordConfidences: transcription.wordConfidences
                        )
                    )
                }
                continuation.resume(returning: alternatives)
            }

            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if !didResume {
                    task.cancel()
                    didResume = true
                    continuation.resume(throwing: ConcertSongFinderError.speechRecognizerUnavailable)
                }
            }
        }
    }

    private func exportAudioClip(audioURL: URL, timeRange: Range<TimeInterval>) async throws -> URL {
        let duration = max(0, timeRange.upperBound - timeRange.lowerBound)
        guard duration > 0.1 else {
            throw ConcertSongFinderError.unrecognizableAudio
        }

        let asset = AVURLAsset(url: audioURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConcertSongFinder-speech-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConcertSongFinderError.unsupportedMedia
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: timeRange.lowerBound, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        try await exportSession.export(to: outputURL, as: .m4a)

        return outputURL
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private extension Array where Element == Float {
    var average: Double? {
        guard !isEmpty else { return nil }
        return Double(reduce(0, +)) / Double(count)
    }
}

private extension SFTranscription {
    var wordConfidences: [String: Double] {
        var values: [String: Double] = [:]
        for segment in segments {
            values[segment.substring] = max(values[segment.substring] ?? 0, Double(segment.confidence))
        }
        return values
    }
}
