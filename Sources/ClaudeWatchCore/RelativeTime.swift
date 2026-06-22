import Foundation

public enum RelativeTime {
    /// Compact "just now / 5m / 2h / 3d / Jun 12" style stamp.
    public static func string(from date: Date, now: Date = Date()) -> String {
        if date == .distantPast { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "now" }
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(Int(hours))h" }
        let days = hours / 24
        if days < 7 { return "\(Int(days))d" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
