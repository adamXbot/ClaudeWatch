import Foundation

/// Parses transcript timestamps.
///
/// Both tools write `2026-06-22T01:14:40.425Z`. That exact shape (and the same without
/// the milliseconds) is decoded by hand: `ISO8601DateFormatter` costs tens of microseconds
/// a call, and the session tracker needs the time of every record in a transcript.
/// Anything else still goes through the formatters, so the result is the same either way.
enum ISOTimestamp {

    static func date(from string: String) -> Date? {
        fast(string) ?? isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    // ISO-8601 with fractional seconds (e.g. "2026-06-22T01:14:40.425Z").
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.mmmZ`, UTC, with every field in
    /// range; nil for any other shape.
    static func fast(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { b -> Date? in
            guard b.count == 20 || b.count == 24 else { return nil }
            func number(_ from: Int, _ length: Int) -> Int? {
                var value = 0
                for i in from..<(from + length) {
                    let digit = Int(b[i]) - 48
                    guard digit >= 0 && digit <= 9 else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,   // - - T : :
                  b[b.count - 1] == 90,                                            // Z
                  let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
            else { return nil }

            var millis = 0
            if b.count == 24 {
                guard b[19] == 46, let m = number(20, 3) else { return nil }       // .
                millis = m
            }

            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard year >= 1970, month >= 1, month <= 12, day >= 1, day <= lengths[month - 1],
                  hour <= 23, minute <= 59, second <= 59
            else { return nil }

            // Days since 1970-01-01 in the proleptic Gregorian calendar.
            let y = month <= 2 ? year - 1 : year
            let era = y / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468

            let milliseconds = ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis
            return Date(timeIntervalSinceReferenceDate: Double(milliseconds) / 1000 - Date.timeIntervalBetween1970AndReferenceDate)
        }
    }
}
