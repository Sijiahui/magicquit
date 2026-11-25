import Foundation

/// Fixed idle-duration steps offered in Settings: one control, no unit picker.
enum IdleDuration {
    static let stepsInMinutes = [15, 30, 60, 120, 180, 240, 480, 720, 1440, 2880]
    static let defaultMinutes = 480

    static func label(minutes: Int) -> String {
        shortRemaining(seconds: minutes * 60)
    }

    /// Smallest step that is at least the given duration; used when migrating 1.x
    /// settings. Rounding up on purpose: apps must never quit earlier than the
    /// user configured. Durations beyond the largest step clamp to it.
    static func stepAtLeast(minutes: Int) -> Int {
        stepsInMinutes.first { $0 >= minutes } ?? stepsInMinutes.last ?? defaultMinutes
    }

    static func stepDown(from minutes: Int) -> Int {
        stepsInMinutes.last { $0 < minutes } ?? stepsInMinutes.first ?? minutes
    }

    static func stepUp(from minutes: Int) -> Int {
        stepsInMinutes.first { $0 > minutes } ?? stepsInMinutes.last ?? minutes
    }

    /// "42 min", "3 h", "12 s" — menu countdown display.
    static func shortRemaining(seconds: Int) -> String {
        if seconds >= 3600 { return String.localizedStringWithFormat(String(localized: "%ld h"), seconds / 3600) }
        if seconds >= 60 { return String.localizedStringWithFormat(String(localized: "%ld min"), seconds / 60) }
        return String.localizedStringWithFormat(String(localized: "%ld s"), max(seconds, 0))
    }
}
