import Foundation

public enum TextNormalizer {
    private static let contractions: [String: String] = [
        "can't": "cannot",
        "won't": "will not",
        "n't": " not",
        "'re": " are",
        "'ve": " have",
        "'ll": " will",
        "'d": " would",
        "'m": " am",
        "i'm": "i am",
        "it's": "it is",
        "that's": "that is"
    ]

    public static func normalizedSongKey(title: String, artist: String, isrc: String? = nil) -> String {
        if let isrc, !isrc.isEmpty {
            return "isrc:\(isrc.uppercased())"
        }
        let title = normalizeSongTitle(title)
        let artist = normalizeText(artist)
        return "\(artist)|\(title)"
    }

    public static func normalizeSongTitle(_ title: String) -> String {
        var value = normalizeText(title)
        let suffixes = [
            " remastered",
            " remaster",
            " explicit",
            " deluxe edition",
            " radio edit",
            " album version",
            " live"
        ]
        for suffix in suffixes where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A looser title key for matching recognized songs against setlist
    /// entries: strips parenthetical/bracketed qualifiers and featured-artist
    /// clauses so "Dramatic Girl (feat. Che Ecru)" matches "Dramatic Girl".
    public static func comparableSongTitle(_ title: String) -> String {
        var value = title.replacingOccurrences(
            of: "\\([^)]*\\)|\\[[^\\]]*\\]",
            with: " ",
            options: .regularExpression
        )
        value = normalizeSongTitle(value)
        for marker in [" feat ", " featuring ", " ft ", " with "] {
            if let range = value.range(of: marker) {
                value = String(value[..<range.lowerBound])
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeText(_ text: String) -> String {
        var value = text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping

        for (key, replacement) in contractions {
            value = value.replacingOccurrences(of: key, with: replacement)
        }

        var scalars: [UnicodeScalar] = []
        var previousWasSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                scalars.append(" ")
                previousWasSpace = true
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func tokens(_ text: String) -> [String] {
        normalizeText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func removeFillerTokens(_ tokens: [String]) -> [String] {
        let filler: Set<String> = ["uh", "um", "yeah", "oh", "ah", "hey", "come", "on"]
        return tokens.filter { !filler.contains($0) }
    }

    public static func characterNGrams(_ text: String, n: Int = 3) -> [String] {
        let normalized = normalizeText(text).replacingOccurrences(of: " ", with: "")
        guard normalized.count >= n else { return normalized.isEmpty ? [] : [normalized] }
        let chars = Array(normalized)
        return (0...(chars.count - n)).map { String(chars[$0..<($0 + n)]) }
    }
}
