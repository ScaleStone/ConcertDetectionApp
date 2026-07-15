import Foundation

enum Formatting {
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}
