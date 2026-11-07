import Foundation

/// The hours someone rests: messages that reach them then arrive without sound.
///
/// They are kept in the person's own bio as a short tag, so that anyone's Telegram app can read them and no server change
/// is needed:
///
///     Product designer at Northbridge 🌙 23:00-08:00 (GMT+1)
///
/// The times are on the person's own clock, whose offset from GMT the tag carries. This app hides the tag from the bio
/// and shows the hours on their own; other apps show it as part of the bio, which reads well enough.
public struct QuietHours: Equatable {
    public static let minimumDurationMinutes = 30
    public static let symbol = "🌙"

    /// When they start and end, in minutes from midnight on the owner's clock.
    public let startMinute: Int
    public let endMinute: Int
    /// The owner's offset from GMT, in seconds, when the hours were set.
    public let utcOffset: Int

    public init?(startMinute: Int, endMinute: Int, utcOffset: Int) {
        guard (0 ..< 24 * 60).contains(startMinute), (0 ..< 24 * 60).contains(endMinute), utcOffset % 60 == 0, (-14 * 3600 ... 14 * 3600).contains(utcOffset) else {
            return nil
        }
        let duration = (endMinute - startMinute + 24 * 60) % (24 * 60)
        guard duration >= QuietHours.minimumDurationMinutes, duration <= 24 * 60 - QuietHours.minimumDurationMinutes else {
            return nil
        }
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.utcOffset = utcOffset
    }

    public var durationMinutes: Int {
        return (self.endMinute - self.startMinute + 24 * 60) % (24 * 60)
    }

    // MARK: - Time

    private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// The quiet hours that contain `timestamp` (seconds since 1970), as seconds since 1970, if it falls in them.
    public func window(containing timestamp: Int32) -> Range<Int64>? {
        let offset = Int64(self.utcOffset)
        let local = Int64(timestamp) + offset
        let day = QuietHours.floorDiv(local, 86400) * 86400
        let duration = Int64(self.durationMinutes) * 60
        for dayShift: Int64 in [-86400, 0] {
            let start = day + dayShift + Int64(self.startMinute) * 60
            if local >= start && local < start + duration {
                return (start - offset) ..< (start - offset + duration)
            }
        }
        return nil
    }

    public func isActive(at timestamp: Int32) -> Bool {
        return self.window(containing: timestamp) != nil
    }

    /// The next moment after `timestamp` at which quiet hours start or end.
    public func nextChange(after timestamp: Int32) -> Int32 {
        if let window = self.window(containing: timestamp) {
            return Int32(clamping: window.upperBound)
        }
        let offset = Int64(self.utcOffset)
        let local = Int64(timestamp) + offset
        var start = QuietHours.floorDiv(local, 86400) * 86400 + Int64(self.startMinute) * 60
        if start <= local {
            start += 86400
        }
        return Int32(clamping: start - offset)
    }

    /// The same moments on a clock `utcOffset` seconds from GMT, in minutes from midnight.
    public func minutes(onClockWithOffset utcOffset: Int) -> (start: Int, end: Int) {
        let shift = (utcOffset - self.utcOffset) / 60
        let day = 24 * 60
        return (((self.startMinute + shift) % day + day) % day, ((self.endMinute + shift) % day + day) % day)
    }

    // MARK: - Bio tag

    public static func zoneName(utcOffset: Int) -> String {
        if utcOffset == 0 {
            return "GMT"
        }
        let hours = abs(utcOffset) / 3600
        let minutes = (abs(utcOffset) % 3600) / 60
        let sign = utcOffset < 0 ? "-" : "+"
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        } else {
            return String(format: "GMT%@%d:%02d", sign, hours, minutes)
        }
    }

    private static func clockText(_ minute: Int) -> String {
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// How the hours are written into the bio: `🌙 23:00-08:00 (GMT+1)`.
    public var tag: String {
        return "\(QuietHours.symbol) \(QuietHours.clockText(self.startMinute))-\(QuietHours.clockText(self.endMinute)) (\(QuietHours.zoneName(utcOffset: self.utcOffset)))"
    }

    private static let tagExpression = try? NSRegularExpression(pattern: "(?:^|\\s)\(QuietHours.symbol) ([01]?\\d|2[0-3]):([0-5]\\d)-([01]?\\d|2[0-3]):([0-5]\\d) \\(GMT(?:([+-])(\\d{1,2})(?::([0-5]\\d))?)?\\)\\s*$", options: [])

    /// The bio without its quiet hours tag, and the hours the tag describes.
    public static func split(about: String?) -> (text: String, quietHours: QuietHours?) {
        guard let about, !about.isEmpty else {
            return ("", nil)
        }
        let nsAbout = about as NSString
        guard let expression = QuietHours.tagExpression, let match = expression.firstMatch(in: about, options: [], range: NSRange(location: 0, length: nsAbout.length)) else {
            return (about, nil)
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : nsAbout.substring(with: range)
        }
        guard let startHour = group(1).flatMap(Int.init), let startMinute = group(2).flatMap(Int.init), let endHour = group(3).flatMap(Int.init), let endMinute = group(4).flatMap(Int.init) else {
            return (about, nil)
        }
        var offset = 0
        if let sign = group(5), let hours = group(6).flatMap(Int.init) {
            let minutes = group(7).flatMap(Int.init) ?? 0
            guard hours <= 14 else {
                return (about, nil)
            }
            offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        }
        guard let quietHours = QuietHours(startMinute: startHour * 60 + startMinute, endMinute: endHour * 60 + endMinute, utcOffset: offset) else {
            return (about, nil)
        }
        let text = nsAbout.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, quietHours)
    }

    /// The length of `about` in UTF-16 units (the larger count: an emoji counts as two), for the room the tag takes.
    public static func length(of about: String) -> Int {
        return about.utf16.count
    }

    /// The same local hours on a clock `utcOffset` seconds from GMT: after a change to or from summer time the hours
    /// stay where they were on the owner's clock.
    public func withOffset(_ utcOffset: Int) -> QuietHours? {
        return QuietHours(startMinute: self.startMinute, endMinute: self.endMinute, utcOffset: utcOffset - utcOffset % 60)
    }

    /// The bio `text` with the tag of `quietHours` after it (or without one).
    public static func about(text: String, quietHours: QuietHours?) -> String {
        let text = QuietHours.split(about: text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quietHours else {
            return text
        }
        return text.isEmpty ? quietHours.tag : text + " " + quietHours.tag
    }
}
