import Foundation

public final class DefaultSetlistAlignmentService: SetlistAlignmentService {
    private let minimumMatchScore: Double
    private let unresolvedPenalty: Double

    public init(minimumMatchScore: Double = 0.52, unresolvedPenalty: Double = -0.2) {
        self.minimumMatchScore = minimumMatchScore
        self.unresolvedPenalty = unresolvedPenalty
    }

    public func align(
        observations: [SongObservation],
        to occurrences: [SetlistOccurrence]
    ) -> SetlistAlignment {
        let observations = observations.sorted {
            if $0.videoOrder != $1.videoOrder { return $0.videoOrder < $1.videoOrder }
            return $0.segmentStart < $1.segmentStart
        }
        guard !observations.isEmpty, !occurrences.isEmpty else {
            return SetlistAlignment(
                mappings: [],
                unresolvedObservationIDs: observations.map(\.id),
                totalScore: 0,
                isAmbiguous: false
            )
        }

        let n = observations.count
        let m = occurrences.count
        let impossible = -Double.greatestFiniteMagnitude
        var dp = Array(repeating: Array(repeating: Cell(score: impossible, decision: .start), count: m + 1), count: n + 1)
        dp[0][0] = Cell(score: 0, decision: .start)

        for i in 0...n {
            for j in 0...m {
                let current = dp[i][j].score
                guard current > impossible / 2 else { continue }

                if j < m, current >= dp[i][j + 1].score {
                    dp[i][j + 1] = Cell(score: current, decision: .skipOccurrence)
                }

                if i < n, current + unresolvedPenalty >= dp[i + 1][j].score {
                    dp[i + 1][j] = Cell(score: current + unresolvedPenalty, decision: .unresolved)
                }

                if i < n, j < m {
                    let score = matchScore(observation: observations[i], occurrence: occurrences[j])
                    if score >= minimumMatchScore {
                        let confidenceBonus = observations[i].isUserConfirmed ? 0.25 : confidenceWeight(observations[i].confidenceLabel)
                        let candidate = current + score + confidenceBonus
                        if candidate > dp[i + 1][j + 1].score {
                            dp[i + 1][j + 1] = Cell(score: candidate, decision: .match(matchScore: score))
                        }
                    }
                }
            }
        }

        var i = n
        var j = m
        var mappings: [ObservationAlignment] = []
        var unresolved: [UUID] = []
        while i > 0 || j > 0 {
            let cell = dp[i][j]
            switch cell.decision {
            case .match(let score):
                let observation = observations[i - 1]
                let occurrence = occurrences[j - 1]
                mappings.append(
                    ObservationAlignment(
                        observationID: observation.id,
                        occurrenceID: occurrence.id,
                        occurrenceOverallIndex: occurrence.overallIndex,
                        score: score,
                        ambiguousOccurrenceIDs: []
                    )
                )
                i -= 1
                j -= 1
            case .unresolved:
                unresolved.append(observations[i - 1].id)
                i -= 1
            case .skipOccurrence:
                j -= 1
            case .start:
                if i > 0 {
                    unresolved.append(observations[i - 1].id)
                    i -= 1
                } else if j > 0 {
                    j -= 1
                }
            }
        }

        mappings.reverse()
        unresolved.reverse()
        let observationIndexByID = Dictionary(uniqueKeysWithValues: observations.enumerated().map { ($0.element.id, $0.offset) })
        let allMappings = mappings.enumerated().map { mappingIndex, mapping in
            guard let observationIndex = observationIndexByID[mapping.observationID],
                  let chosenIndex = occurrences.firstIndex(where: { $0.id == mapping.occurrenceID }) else {
                return mapping
            }
            let previousIndex = mappingIndex > 0 ? mappings[mappingIndex - 1].occurrenceOverallIndex : nil
            let nextIndex = mappingIndex + 1 < mappings.count ? mappings[mappingIndex + 1].occurrenceOverallIndex : nil
            let ambiguous = ambiguousOccurrences(
                for: observations[observationIndex],
                chosenIndex: chosenIndex,
                previousMappedIndex: previousIndex,
                nextMappedIndex: nextIndex,
                occurrences: occurrences
            )
            if ambiguous.isEmpty { return mapping }
            return ObservationAlignment(
                observationID: mapping.observationID,
                occurrenceID: mapping.occurrenceID,
                occurrenceOverallIndex: mapping.occurrenceOverallIndex,
                score: mapping.score,
                ambiguousOccurrenceIDs: ambiguous.sorted()
            )
        }
        return SetlistAlignment(
            mappings: allMappings,
            unresolvedObservationIDs: unresolved,
            totalScore: dp[n][m].score,
            isAmbiguous: allMappings.contains { !$0.ambiguousOccurrenceIDs.isEmpty }
        )
    }

    public func candidateWindow(
        forVideoOrder videoOrder: Int,
        observations: [SongObservation],
        occurrences: [SetlistOccurrence],
        alignment: SetlistAlignment,
        radius: Int = 5
    ) -> CandidateSetlistWindow {
        guard !occurrences.isEmpty else {
            return CandidateSetlistWindow(occurrences: [], reason: "No setlist is available.", confidenceModifier: -0.4)
        }
        let observationByID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let anchors = alignment.mappings.compactMap { mapping -> (videoOrder: Int, occurrenceIndex: Int)? in
            guard let observation = observationByID[mapping.observationID] else { return nil }
            return (observation.videoOrder, mapping.occurrenceOverallIndex)
        }
        let previous = anchors.filter { $0.videoOrder < videoOrder }.max { $0.videoOrder < $1.videoOrder }
        let next = anchors.filter { $0.videoOrder > videoOrder }.min { $0.videoOrder < $1.videoOrder }

        let bounds: ClosedRange<Int>
        let reason: String
        let modifier: Double

        switch (previous, next) {
        case let (.some(previous), .some(next)):
            if previous.occurrenceIndex == next.occurrenceIndex {
                let lower = max(0, previous.occurrenceIndex - 1)
                let upper = min(occurrences.count - 1, next.occurrenceIndex + 1)
                bounds = lower...upper
                reason = "Previous and later anchors point to the same setlist area."
                modifier = 0.08
            } else {
                let lower = max(0, min(previous.occurrenceIndex, next.occurrenceIndex))
                let upper = min(occurrences.count - 1, max(previous.occurrenceIndex, next.occurrenceIndex))
                bounds = lower...upper
                reason = "Shortlisted between chronological setlist anchors."
                modifier = 0.16
            }
        case let (.some(previous), .none):
            let lower = max(0, previous.occurrenceIndex)
            let upper = min(occurrences.count - 1, previous.occurrenceIndex + radius)
            bounds = lower...upper
            reason = "Only a previous anchor is available."
            modifier = 0.04
        case let (.none, .some(next)):
            let lower = max(0, next.occurrenceIndex - radius)
            let upper = min(occurrences.count - 1, next.occurrenceIndex)
            bounds = lower...upper
            reason = "Only a later anchor is available."
            modifier = 0.04
        case (.none, .none):
            bounds = 0...(occurrences.count - 1)
            reason = "No reliable setlist anchors are available."
            modifier = -0.25
        }

        return CandidateSetlistWindow(
            occurrences: occurrences.filter { bounds.contains($0.overallIndex) },
            reason: reason,
            confidenceModifier: modifier
        )
    }

    private func matchScore(observation: SongObservation, occurrence: SetlistOccurrence) -> Double {
        let observationTitle = TextNormalizer.normalizeSongTitle(observation.song.title)
        let occurrenceTitle = occurrence.normalizedTitle.isEmpty
            ? TextNormalizer.normalizeSongTitle(occurrence.title)
            : occurrence.normalizedTitle
        let titleScore = observationTitle == occurrenceTitle
            ? 1
            : Similarity.normalizedEditSimilarity(observationTitle, occurrenceTitle)
        let artistScore = TextNormalizer.normalizeText(observation.song.artist) == TextNormalizer.normalizeText(occurrence.artist) ? 1 : 0.45
        return (titleScore * 0.82) + (artistScore * 0.18)
    }

    private func confidenceWeight(_ label: ConfidenceLabel) -> Double {
        switch label {
        case .strong: 0.2
        case .likely: 0.12
        case .possible: 0.04
        case .insufficient: -0.1
        }
    }

    private func ambiguousOccurrences(
        for observation: SongObservation,
        chosenIndex: Int,
        previousMappedIndex: Int?,
        nextMappedIndex: Int?,
        occurrences: [SetlistOccurrence]
    ) -> [String] {
        let lowerBound = previousMappedIndex ?? 0
        let upperBound = nextMappedIndex ?? (occurrences.count - 1)
        let chosenScore = matchScore(observation: observation, occurrence: occurrences[chosenIndex])
        return occurrences.enumerated().compactMap { index, occurrence in
            guard index != chosenIndex,
                  occurrence.overallIndex >= lowerBound,
                  occurrence.overallIndex <= upperBound else { return nil }
            let score = matchScore(observation: observation, occurrence: occurrence)
            return abs(score - chosenScore) <= 0.03 && score >= minimumMatchScore ? occurrence.id : nil
        }
    }
}

private struct Cell {
    let score: Double
    let decision: Decision
}

private enum Decision {
    case start
    case skipOccurrence
    case unresolved
    case match(matchScore: Double)
}
