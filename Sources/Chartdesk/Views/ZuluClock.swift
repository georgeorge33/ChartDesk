import SwiftUI

/// Zulu and local time, side by side, with how far apart they are.
///
/// Every clearance, report and OFP is in Zulu and the menu bar clock is not, so both belong on
/// screen together rather than one of them living in your head. Local is *this Mac's* time
/// zone, which is the only one the app can know: working out the time at the airport in front
/// of you would need a timezone for every ICAO code, and nothing here carries one.
///
/// `TimelineView` rather than a `Timer`: SwiftUI stops asking for dates while the view is off
/// screen, so an occluded or minimised window costs nothing.
struct ZuluClock: View {

    var body: some View {
        // Anchored to the current whole second, so it ticks on the second rather than whenever
        // the view happened to be built.
        let start = Date(timeIntervalSinceReferenceDate:
                            Date().timeIntervalSinceReferenceDate.rounded(.down))

        TimelineView(.periodic(from: start, by: 1)) { context in
            HStack(spacing: 5) {
                Text(ZuluClock.zulu.string(from: context.date))
                    .foregroundStyle(Color.ngAccentText)
                Text(ZuluClock.local.string(from: context.date))
                    .foregroundStyle(.secondary)
                Text(ZuluClock.offsetLabel)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            // Never wrap or shrink: the column is narrow enough that the clock would break
            // across two lines, and the airport's subtitle beside it can truncate instead.
            .fixedSize(horizontal: true, vertical: false)
        }
        .help("Zulu, this Mac's local time, and local's offset from UTC")
    }

    private static let zulu: DateFormatter = {
        let formatter = DateFormatter()
        // A 24-hour aviation clock, not a localised time of day: the format is fixed whatever
        // the Mac's region is set to.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss 'Z'"
        return formatter
    }()

    /// Local runs to the minute where Zulu runs to the second. Zulu is the one you time a
    /// report against; local only has to tell you roughly where the day is.
    private static let local: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The offset as aviation writes it: whole hours where the zone is a whole number of them,
    /// and `+5:30` where it is not, because a third of the world is on a half-hour offset.
    private static var offsetLabel: String {
        let seconds = TimeZone.current.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "(\(sign)\(hours))"
            : String(format: "(%@%d:%02d)", sign, hours, remainder)
    }
}
