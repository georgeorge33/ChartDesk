import AppKit
import SwiftUI

/// What you see for the first moment after launching, over the top of everything.
///
/// It is held until the library's first scan finishes, so a big folder no longer opens onto an
/// empty sidebar that fills in a beat later, and for a short minimum beyond that — a splash
/// that flashes for a tenth of a second reads as a glitch rather than a start.
struct StartupScreen: View {

    /// What is being waited for, if anything.
    let status: String

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

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
                        .font(.caption)
                        .monospacedDigit()
                        // Orange for a candidate, the same as the badge in the corner.
                        .foregroundStyle(version.contains("-") ? Color.orange : Color.ngAccentText)
                        .padding(.top, 3)
                }

                HStack(spacing: 7) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 26)
                .opacity(status.isEmpty ? 0 : 1)

                // The same line the app carries everywhere else. A chart browser for a
                // simulator is exactly the thing somebody might one day reach for in a cockpit.
                Text("For flight simulation use. Not for real-world navigation.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.ngWarning)
                    .padding(.top, 34)
            }
            .padding(40)
        }
        .ignoresSafeArea()
    }
}
