import Foundation

public enum Similarity {
    public static let commonWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "you", "i", "me", "my", "we", "us", "it", "is", "are", "to", "of",
        "in", "on", "for", "with", "that", "this", "yeah", "oh", "uh", "la", "na"
    ]

    public static func diceCoefficient(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let left = Set(lhs)
        let right = Set(rhs)
        let intersection = left.intersection(right).count
        return (2.0 * Double(intersection)) / Double(left.count + right.count)
    }

    public static func orderedLCSScore(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let length = lcsLength(lhs, rhs)
        return Double(length) / Double(max(lhs.count, rhs.count))
    }

    public static func tokenFuzzyScore(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let meaningfulLeft = lhs.filter { !commonWords.contains($0) }
        let meaningfulRight = rhs.filter { !commonWords.contains($0) }
        let base = diceCoefficient(meaningfulLeft.isEmpty ? lhs : meaningfulLeft, meaningfulRight.isEmpty ? rhs : meaningfulRight)
        let order = orderedLCSScore(lhs, rhs)
        return (base * 0.65) + (order * 0.35)
    }

    public static func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let distance = levenshtein(a, b)
        return 1 - (Double(distance) / Double(max(a.count, b.count)))
    }

    public static func commonWordPenalty(tokens: [String]) -> Double {
        guard !tokens.isEmpty else { return 0.4 }
        let commonCount = tokens.filter { commonWords.contains($0) }.count
        let ratio = Double(commonCount) / Double(tokens.count)
        if tokens.count < 3 { return 0.25 }
        return min(0.45, ratio * 0.45)
    }

    private static func lcsLength<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        var current = previous
        for i in 1...lhs.count {
            current[0] = 0
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1] + 1
                } else {
                    current[j] = max(previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    private static func levenshtein<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var previous = Array(0...rhs.count)
        var current = previous
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = min(previous[j - 1], previous[j], current[j - 1]) + 1
                }
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
