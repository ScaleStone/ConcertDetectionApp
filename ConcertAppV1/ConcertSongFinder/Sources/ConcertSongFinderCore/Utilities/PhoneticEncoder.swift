import Foundation

public enum PhoneticEncoder {
    public static func encodePhrase(_ text: String) -> [String] {
        TextNormalizer.tokens(text).map(encodeToken).filter { !$0.isEmpty }
    }

    public static func encodeTokens(_ tokens: [String]) -> [String] {
        tokens.map(encodeToken).filter { !$0.isEmpty }
    }

    public static func encodeToken(_ token: String) -> String {
        var value = TextNormalizer.normalizeText(token)
        guard !value.isEmpty else { return "" }

        let replacements = [
            ("ough", "o"),
            ("augh", "af"),
            ("ph", "f"),
            ("gh", ""),
            ("ck", "k"),
            ("qu", "kw"),
            ("x", "ks"),
            ("z", "s"),
            ("v", "f"),
            ("dg", "j"),
            ("tion", "shn")
        ]
        for (needle, replacement) in replacements {
            value = value.replacingOccurrences(of: needle, with: replacement)
        }

        let chars = Array(value)
        var output: [Character] = []
        for (index, char) in chars.enumerated() {
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            let mapped: Character?
            switch char {
            case "a", "e", "i", "o", "u", "y":
                mapped = index == 0 ? "A" : nil
            case "b", "p":
                mapped = "P"
            case "c":
                mapped = next.map { Set<Character>(["e", "i", "y"]).contains($0) } == true ? "S" : "K"
            case "k", "q", "g":
                mapped = "K"
            case "d", "t":
                mapped = "T"
            case "f":
                mapped = "F"
            case "j":
                mapped = "J"
            case "l":
                mapped = "L"
            case "m", "n":
                mapped = "N"
            case "r":
                mapped = "R"
            case "s":
                mapped = "S"
            case "h", "w":
                mapped = nil
            default:
                mapped = char
            }
            if let mapped, output.last != mapped {
                output.append(mapped)
            }
        }
        return String(output)
    }
}
