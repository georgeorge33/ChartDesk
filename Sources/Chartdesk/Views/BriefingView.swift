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
    @StateObject private var reader = BriefingReader()

    /// How wide the pane has to be before the sections go beside the briefing: SimBrief sets
    /// its OFP sixty-nine characters wide, which with the margins is about 580 points, and the
    /// list is 210 more. The odd longer line — a link, a remark — scrolls sideways.
    private static let roomForSections: CGFloat = 790

    var body: some View {
        if let html = flight.plan?.briefing {
            let outline = reader.outline(of: html)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    BriefingPage(html: outline.html, reader: reader)
                    if geometry.size.width >= Self.roomForSections, !outline.sections.isEmpty {
                        Divider()
                            .overlay(Color.ngSeparator)
                        BriefingSections(sections: outline.sections, reader: reader)
                            .frame(width: 210)
                    }
                }
            }
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
    let reader: BriefingReader

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A briefing is something to read: nothing of its own runs. The one script here is
        // the app's, in a world of its own, and only says which section is at the top.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let scripts = configuration.userContentController
        scripts.add(context.coordinator, contentWorld: .defaultClient, name: "section")
        scripts.addUserScript(WKUserScript(source: Self.whereAmI, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.underPageBackgroundColor = Theme.canvas
        reader.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Loaded again only when the briefing itself changes, so the place you had scrolled
        // to survives everything else redrawing round it.
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(Self.page(html), baseURL: URL(string: "https://www.simbrief.com/"))
        DispatchQueue.main.async { reader.current = 0 }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Which section's anchor is the last above the top of the view, sent whenever the page
    /// has scrolled — at most once a frame — and the last section once the bottom is reached,
    /// where a short one may never get to the top at all.
    private static let whereAmI = """
        (() => {
          let last = -1, waiting = false;
          function report() {
            waiting = false;
            const marks = document.querySelectorAll('a.ofp-mark');
            let current = 0;
            for (let i = 0; i < marks.length; i++) {
              if (marks[i].getBoundingClientRect().top <= 60) { current = i; } else { break; }
            }
            const page = document.scrollingElement;
            if (marks.length && page.scrollTop + window.innerHeight >= page.scrollHeight - 2) {
              current = marks.length - 1;
            }
            if (current !== last) {
              last = current;
              window.webkit.messageHandlers.section.postMessage(current);
            }
          }
          window.addEventListener('scroll', () => {
            if (!waiting) { waiting = true; requestAnimationFrame(report); }
          }, { passive: true });
          report();
        })();
        """

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
          /* Where each section starts: a little above its heading, so a jump to it leaves
             the heading in view rather than tight against the top. */
          a.ofp-mark { display: inline-block; position: relative; top: -14px; width: 0; height: 0; }
        </style></head>
        <body>\(body)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var shown: String?
        private let reader: BriefingReader

        init(reader: BriefingReader) {
            self.reader = reader
        }

        /// The section now at the top, from the script above.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let index = message.body as? Int, index != reader.current else { return }
            reader.current = index
        }

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

// MARK: - Sections

/// A briefing's sections, and its HTML with an anchor where each one starts.
///
/// SimBrief marks them itself, for its PDF's bookmarks: a comment before each heading,
/// `<!--BKMK///Flight Log///1-->`, level 0 for a section and 1 for one inside it — the OFP's
/// summary, its flight log, its winds — so the list follows SimBrief's own outline in any of
/// its layouts. A briefing without the marks is cut at its bracketed headings instead,
/// `[ OFP ]`, `[ ATC FLIGHT PLAN ]`; one with neither has no list.
struct BriefingOutline {

    struct Section: Identifiable, Equatable {
        let id: Int
        let title: String
        let level: Int
    }

    let html: String
    let sections: [Section]

    init(_ source: String) {
        if let marked = Self.anchored(source, at: #"<!--BKMK///(.*?)///(\d)-->"#, keeping: false)
            ?? Self.anchored(source, at: #"<b>\s*\[\s*([^\]<]{2,40}?)\s*\]"#, keeping: true) {
            html = marked.html
            sections = marked.sections
        } else {
            html = source
            sections = []
        }
    }

    /// An anchor put at each match, in place of it or in front of it, and what each says.
    private static func anchored(_ source: String, at pattern: String, keeping: Bool)
    -> (html: String, sections: [Section])? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let text = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return nil }

        var out = ""
        var sections: [Section] = []
        var cursor = 0
        for (index, match) in matches.enumerated() {
            out += text.substring(with: NSRange(location: cursor,
                                                length: match.range.location - cursor))
            out += "<a id=\"ofp-section-\(index)\" class=\"ofp-mark\"></a>"
            if keeping { out += text.substring(with: match.range) }
            cursor = match.range.location + match.range.length

            let title = text.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var level = 0
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                level = Int(text.substring(with: match.range(at: 2))) ?? 0
            }
            sections.append(Section(id: index, title: title.isEmpty ? "Section \(index + 1)" : title,
                                    level: level))
        }
        out += text.substring(from: cursor)
        return (out, sections)
    }
}

/// What the briefing's page and its list of sections share: the page to scroll, and which
/// section is at the top of it.
@MainActor
final class BriefingReader: ObservableObject {

    @Published var current = 0
    weak var webView: WKWebView?
    private var outlined: (source: String, outline: BriefingOutline)?

    /// Worked out once a briefing, not on every redraw.
    func outline(of html: String) -> BriefingOutline {
        if let outlined, outlined.source == html { return outlined.outline }
        let made = BriefingOutline(html)
        outlined = (html, made)
        return made
    }

    /// Straight to a section, its heading at the top. Run in the app's own script world,
    /// which the page's scripts being off does not touch.
    func show(_ section: BriefingOutline.Section) {
        current = section.id
        let script = "document.getElementById('ofp-section-\(section.id)')"
            + "?.scrollIntoView({ block: 'start' })"
        webView?.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }
}

/// The briefing's sections, in the room to the right of it: pressed to go to one, with the
/// one being read picked out as the page scrolls.
private struct BriefingSections: View {

    let sections: [BriefingOutline.Section]
    @ObservedObject var reader: BriefingReader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SECTIONS")
                .font(.ngSmallBold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        row(section)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.ngPanel)
    }

    private func row(_ section: BriefingOutline.Section) -> some View {
        let here = section.id == reader.current
        return Button {
            reader.show(section)
        } label: {
            Text(section.title)
                .font(section.level == 0 ? .ngSmallMedium : .ngSmall)
                .foregroundStyle(here ? Color.white
                                 : section.level == 0 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, section.level == 0 ? 10 : 22)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background(here ? Color.ngAccent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to \(section.title)")
    }
}
