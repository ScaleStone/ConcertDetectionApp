import Foundation

public struct LyricMatchingWeights: Codable, Hashable {
    public var phonetic: Double
    public var token: Double
    public var character: Double
    public var setlistPrior: Double
    public var neighboringSupport: Double

    public init(
        phonetic: Double = 0.45,
        token: Double = 0.25,
        character: Double = 0.15,
        setlistPrior: Double = 0.10,
        neighboringSupport: Double = 0.05
    ) {
        self.phonetic = phonetic
        self.token = token
        self.character = character
        self.setlistPrior = setlistPrior
        self.neighboringSupport = neighboringSupport
    }
}

public final class DefaultLyricMatchingService: LyricMatchingService {
    private let weights: LyricMatchingWeights
    private let likelyThreshold: Double
    private let likelyMargin: Double
    private let possibleThreshold: Double
    private let possibleMargin: Double

    public init(
        weights: LyricMatchingWeights = LyricMatchingWeights(),
        likelyThreshold: Double = 0.78,
        likelyMargin: Double = 0.12,
        possibleThreshold: Double = 0.62,
        possibleMargin: Double = 0.08
    ) {
        self.weights = weights
        self.likelyThreshold = likelyThreshold
        self.likelyMargin = likelyMargin
        self.possibleThreshold = possibleThreshold
        self.possibleMargin = possibleMargin
    }

    public func rankCandidates(
        transcripts: [TranscriptAlternative],
        lyrics: [SongLyrics],
        occurrences: [SetlistOccurrence],
        context: RecognitionContext
    ) -> [SongCandidate] {
        let usableTranscripts = transcripts
            .map { ($0, TextNormalizer.removeFillerTokens(TextNormalizer.tokens($0.text))) }
            .filter { !$0.1.isEmpty }
        guard !usableTranscripts.isEmpty else { return [] }

        let lyricsBySongKey = Dictionary(grouping: lyrics) {
            TextNormalizer.normalizedSongKey(title: $0.song.title, artist: $0.song.artist, isrc: $0.song.isrc)
        }

        var rawCandidates: [(candidate: SongCandidate, component: ComponentScores)] = []

        for occurrence in occurrences {
            let occurrenceKey = TextNormalizer.normalizedSongKey(title: occurrence.title, artist: occurrence.artist)
            let lyricEntry = lyricsBySongKey[occurrenceKey]?.first ?? lyrics.first {
                TextNormalizer.normalizeSongTitle($0.song.title) == TextNormalizer.normalizeSongTitle(occurrence.title)
            }
            guard let lyricEntry, let lyricText = lyricEntry.lyrics, !lyricText.isEmpty else { continue }

            let component = bestComponentScores(
                transcripts: usableTranscripts,
                lyricText: lyricText,
                occurrenceID: occurrence.id,
                context: context
            )
            let label = ConfidenceLabel.possible
            let song = SongIdentity(
                id: lyricEntry.song.id,
                title: occurrence.title,
                artist: occurrence.artist,
                album: lyricEntry.song.album,
                isrc: lyricEntry.song.isrc
            )
            let reasons = reasons(for: component, occurrence: occurrence)
            rawCandidates.append((
                SongCandidate(
                    song: song,
                    setlistOccurrenceID: occurrence.id,
                    evidenceScore: component.total,
                    confidenceLabel: label,
                    reasons: reasons
                ),
                component
            ))
        }

        let sorted = rawCandidates.sorted { $0.candidate.evidenceScore > $1.candidate.evidenceScore }
        guard !sorted.isEmpty else { return [] }

        let topScore = sorted[0].candidate.evidenceScore
        let secondScore = sorted.dropFirst().first?.candidate.evidenceScore ?? 0
        let margin = topScore - secondScore

        return sorted.prefix(3).enumerated().map { index, item in
            let label: ConfidenceLabel
            if index == 0, topScore >= likelyThreshold, margin >= likelyMargin {
                label = .likely
            } else if item.candidate.evidenceScore >= possibleThreshold, (index > 0 || margin >= possibleMargin) {
                label = .possible
            } else {
                label = .insufficient
            }
            return SongCandidate(
                id: item.candidate.id,
                song: item.candidate.song,
                setlistOccurrenceID: item.candidate.setlistOccurrenceID,
                evidenceScore: item.candidate.evidenceScore,
                confidenceLabel: label,
                reasons: item.candidate.reasons
            )
        }
    }

    private func bestComponentScores(
        transcripts: [(TranscriptAlternative, [String])],
        lyricText: String,
        occurrenceID: String,
        context: RecognitionContext
    ) -> ComponentScores {
        let lyricTokens = TextNormalizer.tokens(lyricText)
        guard !lyricTokens.isEmpty else { return ComponentScores() }

        var comparisons: [ComponentScores] = []
        for (_, transcriptTokens) in transcripts {
            let windowSize = max(3, min(lyricTokens.count, transcriptTokens.count + 2))
            let starts = lyricTokens.count <= windowSize ? [0] : Array(0...(lyricTokens.count - windowSize))
            for start in starts {
                let window = Array(lyricTokens[start..<(start + windowSize)])
                comparisons.append(compare(
                    transcriptTokens: transcriptTokens,
                    lyricWindowTokens: window,
                    occurrenceID: occurrenceID,
                    context: context
                ))
            }
        }

        let sorted = comparisons.sorted { $0.total > $1.total }
        guard let best = sorted.first else { return ComponentScores() }
        if sorted.count > 1 {
            let second = sorted[1]
            return ComponentScores(
                phonetic: (best.phonetic + second.phonetic) / 2,
                token: (best.token + second.token) / 2,
                character: (best.character + second.character) / 2,
                setlistPrior: best.setlistPrior,
                neighboringSupport: best.neighboringSupport,
                penalty: max(best.penalty, second.penalty),
                totalOverride: (best.total + second.total) / 2
            )
        }
        return best
    }

    private func compare(
        transcriptTokens: [String],
        lyricWindowTokens: [String],
        occurrenceID: String,
        context: RecognitionContext
    ) -> ComponentScores {
        let transcriptPhonetic = PhoneticEncoder.encodeTokens(transcriptTokens)
        let lyricPhonetic = PhoneticEncoder.encodeTokens(lyricWindowTokens)
        let phonetic = Similarity.orderedLCSScore(transcriptPhonetic, lyricPhonetic)
        let token = Similarity.tokenFuzzyScore(transcriptTokens, lyricWindowTokens)
        let character = Similarity.diceCoefficient(
            TextNormalizer.characterNGrams(transcriptTokens.joined(separator: " ")),
            TextNormalizer.characterNGrams(lyricWindowTokens.joined(separator: " "))
        )
        let prior = context.setlistPriorByOccurrenceID[occurrenceID] ?? 0
        let neighboring = context.neighboringSupportByOccurrenceID[occurrenceID] ?? 0
        let penalty = Similarity.commonWordPenalty(tokens: transcriptTokens)
        return ComponentScores(
            phonetic: phonetic,
            token: token,
            character: character,
            setlistPrior: prior,
            neighboringSupport: neighboring,
            penalty: penalty,
            weights: weights
        )
    }

    private func reasons(for component: ComponentScores, occurrence: SetlistOccurrence) -> [String] {
        var reasons: [String] = []
        if component.phonetic >= 0.65 { reasons.append("Transcript sounds similar to lyrics") }
        if component.token >= 0.55 { reasons.append("Transcript tokens overlap lyric passage") }
        if component.character >= 0.55 { reasons.append("Character n-grams support the match") }
        if component.setlistPrior > 0 { reasons.append("Setlist order supports occurrence \(occurrence.overallIndex + 1)") }
        if component.neighboringSupport > 0 { reasons.append("Neighboring videos support this candidate") }
        if reasons.isEmpty { reasons.append("Weak fallback evidence only") }
        return reasons
    }
}

private struct ComponentScores {
    let phonetic: Double
    let token: Double
    let character: Double
    let setlistPrior: Double
    let neighboringSupport: Double
    let penalty: Double
    private let totalOverride: Double?
    private let weights: LyricMatchingWeights

    init(
        phonetic: Double = 0,
        token: Double = 0,
        character: Double = 0,
        setlistPrior: Double = 0,
        neighboringSupport: Double = 0,
        penalty: Double = 0,
        totalOverride: Double? = nil,
        weights: LyricMatchingWeights = LyricMatchingWeights()
    ) {
        self.phonetic = phonetic
        self.token = token
        self.character = character
        self.setlistPrior = setlistPrior
        self.neighboringSupport = neighboringSupport
        self.penalty = penalty
        self.totalOverride = totalOverride
        self.weights = weights
    }

    var total: Double {
        if let totalOverride { return max(0, min(1, totalOverride)) }
        let score = (phonetic * weights.phonetic) +
            (token * weights.token) +
            (character * weights.character) +
            (setlistPrior * weights.setlistPrior) +
            (neighboringSupport * weights.neighboringSupport) -
            penalty
        return max(0, min(1, score))
    }
}
