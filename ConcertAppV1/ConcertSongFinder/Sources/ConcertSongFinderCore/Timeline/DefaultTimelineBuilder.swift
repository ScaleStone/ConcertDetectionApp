import Foundation

public final class DefaultTimelineBuilder: TimelineBuildingService {
    public init() {}

    public func buildTimeline(
        duration: TimeInterval,
        rawMatches: [RawRecognitionMatch],
        configuration: RecognitionConfiguration = .default
    ) -> [SongSegment] {
        guard duration > 0 else { return [] }
        let observations = Self.bestObservations(rawMatches: rawMatches)
        guard !observations.isEmpty else {
            return [Self.unknownSegment(start: 0, end: duration)]
        }

        let smoothed = smooth(observations: observations, configuration: configuration)
        let runs = Self.runs(from: smoothed)
        guard !runs.isEmpty else {
            return [Self.unknownSegment(start: 0, end: duration)]
        }

        var segments: [SongSegment] = []
        var cursor: TimeInterval = 0

        for index in runs.indices {
            let run = runs[index]
            let nextRun = index + 1 < runs.count ? runs[index + 1] : nil
            let songStart = index == runs.startIndex ? 0 : cursor
            let songEnd: TimeInterval

            if let nextRun, run.songKey != nextRun.songKey {
                let transition = Self.transitionRange(from: run, to: nextRun, duration: duration)
                songEnd = max(songStart, transition.lowerBound)
                if songEnd - songStart > 0.05 {
                    segments.append(Self.songSegment(for: run, start: songStart, end: songEnd, configuration: configuration))
                }
                let transitionSegment = Self.transitionSegment(from: run, to: nextRun, range: transition)
                if transitionSegment.endTime - transitionSegment.startTime > 0.05 {
                    segments.append(transitionSegment)
                }
                cursor = transition.upperBound
            } else {
                songEnd = duration
                if songEnd - songStart > 0.05 {
                    segments.append(Self.songSegment(for: run, start: songStart, end: songEnd, configuration: configuration))
                }
                cursor = songEnd
            }
        }

        if cursor < duration - 0.05 {
            segments.append(Self.unknownSegment(start: cursor, end: duration))
        }

        return mergeCompatibleSegments(segments, configuration: configuration)
    }

    private func smooth(
        observations: [WindowSongObservation],
        configuration: RecognitionConfiguration
    ) -> [WindowSongObservation] {
        guard observations.count >= 3 else { return observations }
        var result = observations

        for index in 1..<(result.count - 1) {
            let previous = result[index - 1]
            let current = result[index]
            let next = result[index + 1]
            if previous.songKey == next.songKey, current.songKey != previous.songKey {
                result[index] = WindowSongObservation(
                    windowStart: current.windowStart,
                    windowEnd: current.windowEnd,
                    match: previous.match,
                    songKey: previous.songKey,
                    wasSmoothed: true
                )
            }
        }

        var runs = Self.runs(from: result)
        for runIndex in runs.indices where runs[runIndex].observations.count < configuration.minimumSupportingWindowsForChange {
            guard runIndex > runs.startIndex, runIndex + 1 < runs.endIndex else { continue }
            let previous = runs[runIndex - 1]
            let next = runs[runIndex + 1]
            if previous.songKey == next.songKey {
                for observation in runs[runIndex].observations {
                    if let resultIndex = result.firstIndex(where: { $0.windowStart == observation.windowStart && $0.windowEnd == observation.windowEnd }) {
                        result[resultIndex] = WindowSongObservation(
                            windowStart: observation.windowStart,
                            windowEnd: observation.windowEnd,
                            match: previous.observations.last?.match ?? previous.representative,
                            songKey: previous.songKey,
                            wasSmoothed: true
                        )
                    }
                }
            }
        }
        runs = Self.runs(from: result)
        return runs.flatMap(\.observations)
    }

    private func mergeCompatibleSegments(
        _ segments: [SongSegment],
        configuration: RecognitionConfiguration
    ) -> [SongSegment] {
        var result: [SongSegment] = []
        var index = 0
        while index < segments.count {
            let current = segments[index]
            if index + 2 < segments.count,
               current.status != .transition,
               current.status != .unknown,
               segments[index + 1].status == .unknown,
               segments[index + 1].endTime - segments[index + 1].startTime <= configuration.mergeUnknownGapThreshold,
               sameSong(current.primaryCandidate?.song, segments[index + 2].primaryCandidate?.song),
               segments[index + 2].status != .transition,
               segments[index + 2].status != .unknown {
                var merged = current
                merged.endTime = segments[index + 2].endTime
                merged.evidence.shazamWindowCount += segments[index + 2].evidence.shazamWindowCount
                merged.evidence.shazamMatchedDuration += segments[index + 2].evidence.shazamMatchedDuration
                result.append(merged)
                index += 3
            } else {
                result.append(current)
                index += 1
            }
        }
        return result
    }

    private func sameSong(_ lhs: SongIdentity?, _ rhs: SongIdentity?) -> Bool {
        guard let lhs, let rhs else { return false }
        return TextNormalizer.normalizedSongKey(title: lhs.title, artist: lhs.artist, isrc: lhs.isrc) ==
            TextNormalizer.normalizedSongKey(title: rhs.title, artist: rhs.artist, isrc: rhs.isrc)
    }

    private static func bestObservations(rawMatches: [RawRecognitionMatch]) -> [WindowSongObservation] {
        let grouped = Dictionary(grouping: rawMatches) {
            "\(Self.rounded($0.windowStart))-\(Self.rounded($0.windowEnd))"
        }
        return grouped.values.compactMap { matches in
            guard let best = matches.max(by: { $0.strength < $1.strength }) else { return nil }
            return WindowSongObservation(
                windowStart: best.windowStart,
                windowEnd: best.windowEnd,
                match: best,
                songKey: TextNormalizer.normalizedSongKey(title: best.song.title, artist: best.song.artist, isrc: best.song.isrc),
                wasSmoothed: false
            )
        }
        .sorted {
            if abs($0.windowStart - $1.windowStart) > 0.001 {
                return $0.windowStart < $1.windowStart
            }
            return $0.windowEnd < $1.windowEnd
        }
    }

    private static func runs(from observations: [WindowSongObservation]) -> [SongRun] {
        var runs: [SongRun] = []
        for observation in observations {
            if var last = runs.popLast() {
                if last.songKey == observation.songKey {
                    last.observations.append(observation)
                    runs.append(last)
                } else {
                    runs.append(last)
                    runs.append(SongRun(songKey: observation.songKey, observations: [observation]))
                }
            } else {
                runs.append(SongRun(songKey: observation.songKey, observations: [observation]))
            }
        }
        return runs
    }

    private static func transitionRange(from previous: SongRun, to next: SongRun, duration: TimeInterval) -> Range<TimeInterval> {
        guard let previousLast = previous.observations.last, let nextFirst = next.observations.first else {
            return 0..<0
        }
        var start = max(previousLast.windowStart, nextFirst.windowStart)
        var end = min(previousLast.windowEnd, nextFirst.windowEnd)
        if end <= start {
            let midpoint = (previousLast.windowEnd + nextFirst.windowStart) / 2
            start = max(0, midpoint - 2)
            end = min(duration, midpoint + 2)
        }
        return max(0, start)..<min(duration, end)
    }

    private static func songSegment(
        for run: SongRun,
        start: TimeInterval,
        end: TimeInterval,
        configuration: RecognitionConfiguration
    ) -> SongSegment {
        let match = run.representative
        let matchedDuration = run.coveredDuration
        let confidence: ConfidenceLabel = run.observations.count >= configuration.minimumSupportingWindowsForChange ||
            matchedDuration >= configuration.minimumStrongMatchedDuration ? .strong : .possible
        let status: SegmentStatus = confidence == .strong ? .identified : .possible
        let candidate = SongCandidate(
            song: match.song,
            setlistOccurrenceID: nil,
            evidenceScore: min(1, (Double(run.observations.count) / 3.0) * match.strength),
            confidenceLabel: confidence,
            reasons: confidence == .strong
                ? ["Supported by overlapping Shazam windows"]
                : ["Single Shazam observation; needs review"]
        )
        return SongSegment(
            startTime: start,
            endTime: end,
            status: status,
            primaryCandidate: candidate,
            evidence: RecognitionEvidence(
                shazamWindowCount: run.observations.count,
                shazamMatchedDuration: matchedDuration,
                classificationSource: .shazamKit
            )
        )
    }

    private static func transitionSegment(from previous: SongRun, to next: SongRun, range: Range<TimeInterval>) -> SongSegment {
        let previousCandidate = SongCandidate(
            song: previous.representative.song,
            setlistOccurrenceID: nil,
            evidenceScore: previous.representative.strength,
            confidenceLabel: .possible,
            reasons: ["Song was supported before this crossover"]
        )
        let nextCandidate = SongCandidate(
            song: next.representative.song,
            setlistOccurrenceID: nil,
            evidenceScore: next.representative.strength,
            confidenceLabel: .possible,
            reasons: ["Song was supported after this crossover"]
        )
        return SongSegment(
            startTime: range.lowerBound,
            endTime: range.upperBound,
            status: .transition,
            primaryCandidate: previousCandidate,
            alternativeCandidates: [nextCandidate],
            evidence: RecognitionEvidence(
                shazamWindowCount: previous.observations.count + next.observations.count,
                shazamMatchedDuration: range.upperBound - range.lowerBound,
                classificationSource: .shazamKit
            )
        )
    }

    private static func unknownSegment(start: TimeInterval, end: TimeInterval) -> SongSegment {
        SongSegment(
            startTime: start,
            endTime: end,
            status: .unknown,
            primaryCandidate: nil,
            evidence: RecognitionEvidence()
        )
    }

    private static func rounded(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}

private struct WindowSongObservation: Hashable {
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let match: RawRecognitionMatch
    let songKey: String
    let wasSmoothed: Bool
}

private struct SongRun: Hashable {
    let songKey: String
    var observations: [WindowSongObservation]

    var representative: RawRecognitionMatch {
        observations.max(by: { $0.match.strength < $1.match.strength })?.match ?? observations[0].match
    }

    var coveredDuration: TimeInterval {
        guard !observations.isEmpty else { return 0 }
        let sorted = observations.sorted { $0.windowStart < $1.windowStart }
        var total: TimeInterval = 0
        var currentStart = sorted[0].windowStart
        var currentEnd = sorted[0].windowEnd
        for observation in sorted.dropFirst() {
            if observation.windowStart <= currentEnd {
                currentEnd = max(currentEnd, observation.windowEnd)
            } else {
                total += currentEnd - currentStart
                currentStart = observation.windowStart
                currentEnd = observation.windowEnd
            }
        }
        total += currentEnd - currentStart
        return total
    }
}
