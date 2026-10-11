import Foundation

/// "Today 00:15", "Yesterday 21:03", "3 days ago": how backup times read in the window.
enum RelativeTime {
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 1 && days < 30 { return String(localized: "\(days) days ago") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The full timestamp, for tooltips.
    static func full(_ date: Date) -> String {
        date.formatted(date: .complete, time: .shortened)
    }
}
