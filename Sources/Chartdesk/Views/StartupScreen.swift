import AppKit
import SwiftUI

/// What you see for the first moment after launching, over the top of everything.
///
/// It is held until the library's first scan finishes, so a big folder no longer opens onto an
/// empty sidebar that fills in a beat later, and for two seconds beyond that — long enough to
/// read, rather than a flash that registers as a glitch.
///
/// It also covers an update installing itself, which is the same picture with a bar in it: the
/// app is going to quit and reopen, and this is a good deal calmer than the window vanishing.
struct StartupScreen: View {

    /// What is being waited for, if anything.
    let status: String

    /// Set while an update installs, which puts a progress bar where the spinner goes.
    var update: UpdateController.Installing?

    private var version: String { Bundle.main.appVersion }

    var body: some View {
        ZStack {
            Color.ngWindow

            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

                Text("Chartdesk")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .padding(.top, 14)

                if !version.isEmpty {
                    Text(version)
                        .font(.ngSmall)
                        .monospacedDigit()
                        // Orange for a candidate, the same as the badge in the corner.
                        .foregroundStyle(Bundle.main.isCandidateBuild ? Color.orange : Color.ngAccentText)
                        .padding(.top, 3)
                }

                // One height for both, so the caution line below does not shift when an
                // update turns the spinner into a bar.
                ZStack {
                    if let update = update {
                        UpdateBar(update: update)
                    } else {
                        HStack(spacing: 7) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                            Text(status)
                                .font(.ngSmall)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(status.isEmpty ? 0 : 1)
                    }
                }
                .frame(height: 26)
                .padding(.top, 24)

                // The same line the app carries everywhere else. A chart browser for a
                // simulator is exactly the thing somebody might one day reach for in a cockpit.
                Text("For flight simulation use. Not for real-world navigation.")
                    .font(.ngSmallMedium)
                    .foregroundStyle(Color.ngWarning)
                    .padding(.top, 34)
            }
            .padding(40)
        }
        .ignoresSafeArea()
    }
}

/// A bar for an install whose length nobody knows.
///
/// `gh` hands back nothing to count — no byte total, nothing on the way through — so this is a
/// shape rather than a measurement: quick off the mark, then flattening, and asymptotic below
/// the end so it cannot run out ahead of a slow download. Filling it is `isFinishing`'s job
/// alone, because the one thing a progress bar must not do is claim to be finished early.
///
/// Read off the clock rather than animated into place. The obvious spelling — `withAnimation`
/// in a `task` — silently does nothing: the change lands in the same transaction as the bar's
/// insertion, so the fraction jumps straight to its target and sits there. It looked plausible
/// in code and shipped a frozen bar at 90% in a screenshot.
private struct UpdateBar: View {

    let update: UpdateController.Installing

    /// When the bar came on screen. Held in state because the view value itself is rebuilt on
    /// every frame, which would reset a plain `let` each time and leave the bar at zero.
    @State private var started = Date.now

    private static let width = 220.0

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { timeline in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.ngPanelRaised)
                    Capsule()
                        .fill(Color.ngAccent)
                        .frame(width: Self.width * fraction(after: timeline.date.timeIntervalSince(started)))
                }
                .frame(width: Self.width, height: 5)
            }
            .frame(height: 5)

            Text(update.isFinishing ? "Restarting…" : "Updating to \(update.version)")
                .font(.ngSmall)
                .foregroundStyle(.secondary)
        }
    }

    private func fraction(after elapsed: TimeInterval) -> Double {
        guard !update.isFinishing else { return 1 }
        // 0.5s in: 0.31. A second: 0.52. Two: 0.75. Five: 0.90. Never past 0.92.
        return 0.92 * (1 - exp(-elapsed / 1.2))
    }
}
