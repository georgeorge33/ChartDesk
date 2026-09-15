import SwiftUI

/// Zulu, beside the airport code it is read against.
///
/// Every clearance, report and OFP is in Zulu and the menu bar clock is not, so the conversion
/// is a small recurring cost worth removing. Only Zulu: a second clock showing this Mac's time
/// zone raised the question of whose time it was, and the honest answer for the airport in
/// front of you needs a timezone for every ICAO code, which nothing here carries.
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
            Text(ZuluClock.formatter.string(from: context.date))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.ngAccentText)
                .lineLimit(1)
                // Never wrap or shrink: the column is narrow enough that the clock would break
                // across two lines, and the airport's subtitle beside it can truncate instead.
                .fixedSize(horizontal: true, vertical: false)
        }
        .help("Current UTC time")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // A 24-hour aviation clock, not a localised time of day: the format is fixed whatever
        // the Mac's region is set to.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss 'Z'"
        return formatter
    }()
}
