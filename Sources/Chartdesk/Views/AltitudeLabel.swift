import SwiftUI

/// An altitude on the flight plan page, coloured and barred the way an Airbus F-PLN shows it.
///
/// Two colours, the two the page uses: green for what the aeroplane is predicted to do, magenta
/// for what it has been told to do. On a real F-PLN only the constrained fix is magenta — every
/// other ALT is dashes or a green prediction — and that is the whole reason the colour carries
/// any meaning. The bars say which kind of restriction it is, and say it without a word: a
/// tooltip reading "cross at or above" would only be describing the bar beside it.
struct AltitudeLabel: View {

    /// The altitude the plan predicts here.
    let feet: Int
    /// The restriction at this fix, when one is known.
    var constraint: AltitudeConstraint?
    /// True when the row above says the same thing, in which case a ditto stands in for it.
    var repeatsAbove = false

    /// Fixed, so the figures line up and a ditto sits under the middle of the one it repeats.
    private static let width: CGFloat = 70

    /// Flight levels above the transition, bare feet below it — the way the page reads them.
    /// No unit: every figure in the column is feet, and saying so twelve times says nothing.
    static func text(for feet: Int) -> String {
        feet >= 18_000 ? String(format: "FL%03d", feet / 100) : "\(feet)"
    }

    private var colour: Color {
        Color(nsColor: constraint == nil ? Theme.prediction : Theme.constraint)
    }

    var body: some View {
        if case .between(let ceiling, let floor) = constraint {
            // Two figures, stacked: a ceiling with its bar above, a floor with its bar below.
            VStack(alignment: .trailing, spacing: 0) {
                bar(AltitudeLabel.text(for: ceiling), above: true, below: false)
                bar(AltitudeLabel.text(for: floor), above: false, below: true)
            }
            .frame(width: Self.width, alignment: .trailing)
        } else if repeatsAbove {
            Text("\"")
                .font(.ngSmallMono)
                .foregroundStyle(colour)
                // A quote mark hangs from the cap line, which beside a run of figures reads as
                // a mistake rather than a repeat. This drops it onto the middle of the row.
                .baselineOffset(-3)
                .frame(width: Self.width, alignment: .center)
        } else {
            figure
                .frame(width: Self.width, alignment: .trailing)
        }
    }

    /// The bars hug the figure rather than the column, so a rule is as wide as what it governs.
    private var figure: some View {
        Text(AltitudeLabel.text(for: constraint?.feet ?? feet))
            .font(.ngSmallMono)
            .monospacedDigit()
            .foregroundStyle(colour)
            .padding(.vertical, 2)
            .overlay(alignment: .top) {
                if constraint?.hasBarAbove == true { rule }
            }
            .overlay(alignment: .bottom) {
                if constraint?.hasBarBelow == true { rule }
            }
    }

    private func bar(_ text: String, above: Bool, below: Bool) -> some View {
        Text(text)
            .font(.ngSmallMono)
            .monospacedDigit()
            .foregroundStyle(colour)
            .padding(.vertical, 1)
            .overlay(alignment: .top) { if above { rule } }
            .overlay(alignment: .bottom) { if below { rule } }
    }

    private var rule: some View {
        Rectangle()
            .fill(colour)
            .frame(height: 1)
    }
}
