import AppKit
import SwiftUI
import WebKit

/// The loaded flight's SimBrief briefing, the way SimBrief lays it out.
///
/// The OFP comes with the plan, as the HTML SimBrief sends it in, so reading it needs no
/// second request and no browser: it is shown in a web view with the app's colours round
/// it, scripts off, and any link in it sent to the browser rather than followed in here.
struct BriefingView: View {

    @EnvironmentObject private var flight: FlightPlanStore

    var body: some View {
        if let html = flight.plan?.briefing {
            BriefingPage(html: html)
                .background(Color(nsColor: Theme.canvas))
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(flight.plan == nil ? "No flight loaded" : "No briefing with this flight")
                .font(.headline)
            Text(flight.plan == nil
                 ? "Fetch your latest SimBrief flight and its briefing is shown here."
                 : "It was fetched before Chartdesk kept the briefing. Fetch it again "
                   + "and the briefing comes with it.")
                .font(.ngSmall)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            FetchAgainButton()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ngWindow)
    }
}

/// The column beside the briefing: which flight it is, when SimBrief made it, and the two
/// things worth doing with it besides reading it — fetching it again, and opening SimBrief's
/// own PDF of it.
struct BriefingColumn: View {

    @EnvironmentObject private var flight: FlightPlanStore

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.ngSeparator)

            VStack(alignment: .leading, spacing: 14) {
                if let plan = flight.plan {
                    VStack(alignment: .leading, spacing: 3) {
                        detail("Flight", plan.title)
                        if let aircraft = plan.aircraft { detail("Aircraft", aircraft) }
                        if let layout = plan.layout { detail("Layout", layout) }
                        if let made = plan.generatedAt { detail("Made", Self.zulu(made)) }
                        detail("Fetched", Self.zulu(plan.fetchedAt))
                    }
                    .font(.ngSmall)

                    VStack(alignment: .leading, spacing: 8) {
                        FetchAgainButton()
                        if let address = plan.briefingPDF, let url = URL(string: address) {
                            Link(destination: url) {
                                Label("Open SimBrief's PDF", systemImage: "arrow.up.forward.square")
                            }
                            .font(.ngSmall)
                            .help("The same briefing as a PDF, in your browser")
                        }
                    }
                }

                if let problem = flight.problem {
                    Text(problem)
                        .font(.ngSmall)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 250)
        .background(Color.ngPanel)
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text("Briefing")
                .font(.system(size: 18, weight: .semibold))
            if let plan = flight.plan {
                Text(plan.pair)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("SimBrief" + (plan.layout.map { " · \($0) layout" } ?? ""))
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No flight loaded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// In UTC, which is what a briefing's own times are in.
    private static func zulu(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "d MMM, HH:mm'Z'"
        return format.string(from: date)
    }
}

/// Fetches the latest flight from SimBrief again, which brings its latest briefing with it.
private struct FetchAgainButton: View {

    @EnvironmentObject private var flight: FlightPlanStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                flight.refresh()
            } label: {
                Label("Fetch Again from SimBrief", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(flight.isFetching || !flight.hasAccount)
            .help(flight.hasAccount ? "Your latest SimBrief flight, and its briefing"
                                    : "Add your SimBrief username in Settings first")
            if flight.isFetching {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }
}

/// The briefing's own HTML in a web view: SimBrief's layout kept, the app's colours put round
/// it, and nothing in it run.
private struct BriefingPage: NSViewRepresentable {

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A briefing is something to read. Nothing in it needs to run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.underPageBackgroundColor = Theme.canvas
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Loaded again only when the briefing itself changes, so the place you had scrolled
        // to survives everything else redrawing round it.
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(Self.page(html), baseURL: URL(string: "https://www.simbrief.com/"))
    }

    /// SimBrief's OFP is preformatted text in a few divs, written for black on white: here it
    /// is light on the chart backdrop, in the system's monospaced face, with the images it
    /// links to — wind charts, in some layouts — on a white card of their own.
    static func page(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: dark; }
          html, body { background: #000810; margin: 0; }
          body { color: #DCE4EC; padding: 22px 28px 48px;
                 font: 12.5px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
          pre { font: inherit !important; white-space: pre; margin: 0 0 1em; }
          div { line-height: 1.45 !important; }
          b, strong { color: #FFFFFF; }
          a { color: #30B8F0; }
          img { max-width: 100%; height: auto; background: #FFFFFF; border-radius: 4px; }
        </style></head>
        <body>\(body)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?

        /// The page itself loads; a link clicked in it opens in the browser instead.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
