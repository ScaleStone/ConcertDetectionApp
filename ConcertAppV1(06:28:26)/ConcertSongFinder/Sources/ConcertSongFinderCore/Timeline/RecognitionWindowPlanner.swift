import Foundation

public struct RecognitionWindow: Identifiable, Codable, Hashable {
    public let id: UUID
    public let start: TimeInterval
    public let end: TimeInterval

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public enum RecognitionWindowPlanner {
    public static func windows(duration: TimeInterval, configuration: RecognitionConfiguration = .default) -> [RecognitionWindow] {
        guard duration > 0 else { return [] }
        let windowLength = configuration.windowLength
        let step = configuration.stepSize
        guard windowLength > 0, step > 0 else {
            return [RecognitionWindow(start: 0, end: duration)]
        }

        if duration <= windowLength {
            return [RecognitionWindow(start: 0, end: duration)]
        }

        var result: [RecognitionWindow] = []
        var start: TimeInterval = 0
        while start < duration {
            let end = min(duration, start + windowLength)
            result.append(RecognitionWindow(start: start, end: end))
            if end >= duration { break }
            start += step
        }

        if let last = result.last, last.end < duration {
            result.append(RecognitionWindow(start: max(0, duration - windowLength), end: duration))
        }
        return result
    }

    public static func refinedWindows(
        around range: Range<TimeInterval>,
        duration: TimeInterval,
        configuration: RecognitionConfiguration = .default
    ) -> [RecognitionWindow] {
        let padding = configuration.refinedWindowLength
        let lower = max(0, range.lowerBound - padding)
        let upper = min(duration, range.upperBound + padding)
        let localConfig = RecognitionConfiguration(
            windowLength: configuration.refinedWindowLength,
            stepSize: configuration.refinedStepSize,
            refinedWindowLength: configuration.refinedWindowLength,
            refinedStepSize: configuration.refinedStepSize,
            minimumSupportingWindowsForChange: configuration.minimumSupportingWindowsForChange,
            minimumStrongMatchedDuration: configuration.minimumStrongMatchedDuration,
            mergeUnknownGapThreshold: configuration.mergeUnknownGapThreshold,
            processingVersion: configuration.processingVersion
        )
        return windows(duration: upper - lower, configuration: localConfig)
            .map { RecognitionWindow(start: $0.start + lower, end: $0.end + lower) }
    }
}
