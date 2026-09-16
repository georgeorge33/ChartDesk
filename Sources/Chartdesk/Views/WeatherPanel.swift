import AppKit
import SwiftUI

/// Weather, ATIS and the wind against your runways, at the foot of the chart list.
///
/// Everything lives here rather than in a window of its own: the airport you want weather for
/// is almost always the one whose charts you are reading, and a second window would mean
/// keeping two selections in step.
///
/// Collapsed it fetches nothing, so closing it stops the traffic rather than hiding it.
struct WeatherPanel: View {

    @EnvironmentObject private var weather: WeatherStore
    @EnvironmentObject private var library: ChartLibrary

    /// The airport the chart list is showing. The panel follows it unless you type another.
    let icao: String?
    /// Height of the whole chart-list column, so the panel cannot be dragged over the list.
    let available: CGFloat

    @State private var query = ""
    @State private var picked: String?
    /// Panel height when the current drag started, so the drag is absolute rather than a
    /// running sum of deltas.
    @State private var heightAtDragStart: CGFloat?

    private var code: String? { weather.icao }

    /// Everything the panel needs to draw itself, worked out once.
    ///
    /// These used to be computed properties, and SwiftUI evaluates one of those every time it
    /// is read: the runway list came out of the library three times per redraw, the METAR was
    /// parsed four times, and the wind resolved three. Same answers each time. On a large
    /// library the runway derivation alone was 60 microseconds a go.
    private struct Resolved {
        let report: AirportWeather?
        let wind: WindObservation?
        /// What the airport is known to have, independent of what is picked.
        let known: [String]
        /// What the wind is resolved against: the known runways, plus a pick from the full list.
        let runways: [String]
        let winds: [RunwayWind]
        let selected: RunwayWind?
        let best: String?

        /// What the menu offers: every designator when the library knows nothing about the
        /// airport, which is the case for one typed into the field.
        ///
        /// Deliberately not derived from `runways` — that includes whatever is picked, so
        /// choosing 18 at an unknown airport would leave 18 as the only thing in the menu.
        var choices: [String] { known.isEmpty ? WindMath.allDesignators : known }
    }

    private func resolve() -> Resolved {
        let report = weather.weather(for: code)
        let wind = report?.metar.flatMap(WindMath.parse)

        let fromCharts = library.airport(code: code)?.charts.compactMap(\.runway) ?? []
        let remembered = weather.runwayList(for: code)
        let known = WindMath.candidates(fromCharts: fromCharts, remembered: remembered)
        // With nothing picked the two lists are the same, so the expensive derivation runs
        // once rather than twice.
        let runways = picked == nil
            ? known
            : WindMath.candidates(fromCharts: fromCharts, remembered: remembered, including: picked)

        var winds: [RunwayWind] = []
        if let wind = wind {
            winds = WindMath.components(wind: wind,
                                        variationWest: weather.variation(for: code),
                                        runways: runways)
        }
        let best = WindMath.best(winds)
        let selected = winds.first { $0.runway == picked } ?? best

        return Resolved(report: report, wind: wind, known: known, runways: runways,
                        winds: winds, selected: selected, best: best?.runway)
    }

    /// Optional, so an airport we know no runways for shows a placeholder rather than
    /// volunteering 01 as though it were a real answer.
    private func runwayChoice(_ resolved: Resolved) -> Binding<String?> {
        Binding(get: { picked ?? resolved.selected?.runway ?? resolved.known.first },
                set: { picked = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if weather.isExpanded { resizeHandle }
            header
            if weather.isExpanded {
                Divider().overlay(Color.ngSeparator)
                // Worked out once here and handed down, rather than each reader triggering
                // its own evaluation.
                content(resolve())
            }
        }
        .background(Color.ngPanelRaised)
        .onAppear { query = code ?? icao ?? "" }
        .onChange(of: weather.icao) { _, newValue in
            query = newValue ?? ""
            // A runway chosen at the last airport means nothing at this one.
            picked = nil
        }
    }

    // MARK: Resizing

    /// The tallest the panel may be drawn: what the column can spare while leaving the chart
    /// list a usable stub. Permissive until the first layout pass has measured anything.
    private var ceiling: CGFloat {
        available <= 0
            ? WeatherStore.panelHeightRange.upperBound
            : max(WeatherStore.panelHeightRange.lowerBound, available - 240)
    }

    /// Fixed rather than a maximum. Two greedy siblings in a stack split the space between
    /// them, so a cap stopped the panel at half the column however far you dragged.
    private var contentHeight: CGFloat {
        min(weather.panelHeight, ceiling)
    }

    /// Drag the top edge to trade height with the chart list.
    private var resizeHandle: some View {
        PanelResizeGrip(onBegin: { heightAtDragStart = weather.panelHeight },
                        onDrag: { up in
                            let start = heightAtDragStart ?? weather.panelHeight
                            heightAtDragStart = start
                            weather.panelHeight =
                                min(max(start + up, WeatherStore.panelHeightRange.lowerBound),
                                    ceiling)
                        },
                        onEnd: {
                            heightAtDragStart = nil
                            weather.savePanelHeight()
                        })
            .frame(height: 9)
            .help("Drag to resize")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                weather.isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: weather.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.ngSmallBold)
                    Text("Weather")
                        .font(.ngSmallMedium)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if weather.isExpanded {
                // Typed rather than fixed to the selection, so weather for a destination you
                // hold no charts for is still one field away.
                TextField("ICAO", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.ngSmall)
                    .frame(width: 66)
                    .onSubmit(lookUp)
            } else if let code = code {
                Text(code).font(.ngSmall).foregroundStyle(Color.ngAccentText)
            }

            Spacer(minLength: 0)

            if let age = weather.age(for: code), weather.isExpanded {
                Text(age).font(.ngSmall).foregroundStyle(.tertiary)
            }

            if weather.isFetching {
                ProgressView().progressViewStyle(.circular).controlSize(.mini)
            } else if weather.isExpanded {
                Button {
                    weather.refresh(code)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ngAccentText)
                .help("Fetch the latest weather and ATIS")
            }
        }
        .font(.ngSmall)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func lookUp() {
        let wanted = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard wanted.count == 4 else { query = code ?? ""; return }
        picked = nil
        weather.show(icao: wanted)
    }

    // MARK: Content

    private func content(_ resolved: Resolved) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = weather.problem {
                    Text(problem).font(.ngSmall).foregroundStyle(Color.orange)
                } else if resolved.report == nil {
                    Text(weather.isFetching ? "Fetching…" : "No weather loaded.")
                        .font(.ngSmall)
                        .foregroundStyle(.tertiary)
                }

                if resolved.report != nil { windSection(resolved) }

                if let report = resolved.report {
                    // METAR and TAF above ATIS: a full ATIS runs to ten lines of hold-short
                    // and crane advisories and would push them out of view.
                    if let metar = report.metar { reportBlock("METAR", metar, mono: true) }
                    if let taf = report.taf { reportBlock("TAF", taf, mono: true) }
                    ForEach(report.realAtis) {
                        reportBlock($0.label, $0.text, mono: false, showsAge: true)
                    }
                    ForEach(report.vatsimAtis) {
                        reportBlock("VATSIM \($0.label)", $0.text,
                                    accent: Color(nsColor: Theme.category(.arrival)),
                                    mono: false, showsAge: true)
                    }
                    ForEach(report.notes, id: \.self) { note in
                        Text(note)
                            .font(.ngSmall)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: contentHeight)
    }

    // MARK: Wind

    @ViewBuilder
    private func windSection(_ resolved: Resolved) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(resolved.wind?.summary ?? "No wind reported")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text("var")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                TextField("", value: variationBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.ngSmall)
                    .frame(width: 40)
                Text("°W")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("RWY")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                Picker("", selection: runwayChoice(resolved)) {
                    if runwayChoice(resolved).wrappedValue == nil {
                        Text("—").tag(String?.none)
                    }
                    ForEach(resolved.choices, id: \.self) { runway in
                        Text(runway).tag(String?.some(runway))
                    }
                }
                .labelsHidden()
                .font(.ngSmall)
                .frame(width: 84)
                Spacer(minLength: 0)
            }

            // Between the field and the rows: the two settings sit together at the top, and
            // the picture sits directly above the list that picks what it draws.
            if let selected = resolved.selected {
                RunwayWindDiagram(selected: selected)
                    .frame(height: 162)
                    .frame(maxWidth: .infinity)
            }

            if resolved.winds.isEmpty {
                Text(resolved.runways.isEmpty
                     ? "Pick a runway and the wind will be resolved against it."
                     : (resolved.wind == nil
                        ? "No wind in the report — nothing to resolve."
                        : (resolved.wind?.isCalm == true
                           ? "Wind is calm — nothing to resolve."
                           : "Wind is variable — no steady direction to resolve.")))
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(resolved.winds) { entry in
                    row(entry, isBest: entry.runway == resolved.best,
                        selected: resolved.selected?.runway)
                }
                // METAR wind is true north, runway numbers are magnetic. Without the variation
                // the components are quietly wrong by exactly that much.
                Text("METAR wind is true, runway numbers are magnetic — set the variation from "
                     + "the chart. The star is the most headwind of these, not what ATC will give you.")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: RunwayWind, isBest: Bool, selected: String?) -> some View {
        // Compare against the resolved selection, not `picked`, so the highlighted row is
        // always the runway the diagram is drawing.
        let chosen = selected == entry.runway
        return Button {
            picked = chosen ? nil : entry.runway
        } label: {
            HStack(spacing: 7) {
                Text(entry.runway)
                    .font(.ngSmallMono)
                    .frame(width: 30, alignment: .leading)
                Text(entry.shortHeadwind)
                    .foregroundStyle(entry.isTailwind ? Color.orange : Color.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(entry.shortCrosswind)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isBest {
                    Image(systemName: "star.fill")
                        .font(.ngSmall)
                        .foregroundStyle(Color.ngAccentText)
                }
            }
            .font(.ngSmall)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(chosen ? Color.ngAccent.opacity(0.5) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.gustCrosswind.map { "\(entry.crosswindLabel), gusting to \(Int($0.rounded())) kt across" }
              ?? entry.crosswindLabel)
    }

    private var variationBinding: Binding<Double> {
        Binding(get: { weather.variation(for: code) },
                set: { weather.setVariation($0, for: code) })
    }

    /// A report with its key values coloured. `showsAge` puts the "+n mins" beside the title,
    /// which only an ATIS carries a time group for.
    private func reportBlock(_ title: String,
                             _ text: String,
                             accent: Color = Color.ngAccentText,
                             mono: Bool,
                             showsAge: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.ngSmallBold)
                    .foregroundStyle(accent)
                if showsAge { AtisAge(text: text) }
            }
            Text(WeatherPanel.marked(text))
                .font(mono ? .ngSmallMono : .ngSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A report with its key values coloured, built by appending runs so the index arithmetic
    /// stays in one place. Every run is given a colour explicitly, including the plain ones: a
    /// `foregroundStyle` on the `Text` would otherwise decide which of the two wins.
    static func marked(_ text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex

        func plain(_ slice: Substring) {
            var run = AttributedString(slice)
            run.foregroundColor = .secondary
            result += run
        }

        for span in AtisMarkup.spans(in: text) {
            if cursor < span.range.lowerBound {
                plain(text[cursor..<span.range.lowerBound])
            }
            var run = AttributedString(text[span.range])
            run.foregroundColor = span.kind == .key ? Color.ngAccentText : Color.orange
            result += run
            cursor = span.range.upperBound
        }
        plain(text[cursor...])
        return result
    }
}

// MARK: - ATIS age

/// How long ago the report in front of you was issued, from the time group it carries.
///
/// A new ATIS goes out at least hourly and immediately on a significant change, so the number
/// is how much confidence to place in what you are reading. Past an hour it turns orange: at
/// that point a newer letter almost certainly exists.
private struct AtisAge: View {

    let text: String

    var body: some View {
        if let issued = AtisMarkup.issueTime(in: text, now: Date()) {
            // Anchored to the issue time, so the count changes on the minute it actually
            // changes rather than a minute after the view happened to appear.
            TimelineView(.periodic(from: issued, by: 60)) { context in
                let minutes = max(Int(context.date.timeIntervalSince(issued) / 60), 0)
                Text("+\(minutes) min\(minutes == 1 ? "" : "s")")
                    .font(.ngSmall)
                    .monospacedDigit()
                    .foregroundStyle(minutes > 60 ? Color.orange : Color.secondary)
                    .help(minutes > 60
                          ? "Issued \(minutes) minutes ago. An ATIS is reissued at least hourly, "
                            + "so there is probably a newer letter."
                          : "Issued \(minutes) minutes ago")
            }
        }
    }
}

// MARK: - The runway diagram

/// The runway on the left, always pointing up the page, and the wind beside it as the only two
/// numbers that matter: the component along the runway and the component across it.
///
/// The runway is drawn vertically whatever its heading, because on approach the only thing that
/// matters is the wind *relative* to it and a compass rose makes you do that rotation in your
/// head. The two arrows are the decomposition of one wind vector, drawn to a single scale, so
/// their lengths are comparable: a long one down the page and a stub across it is a wind on the
/// nose, and the reverse is the one to think about.
///
/// Each arrow points the way the air moves, which is also the way it pushes you — a headwind
/// arrow runs back towards the threshold, and a wind off the right blows you left.
private struct RunwayWindDiagram: View {

    let selected: RunwayWind

    /// Half the drawn pavement width.
    private let halfWidth: CGFloat = 17

    var body: some View {
        Canvas { context, size in
            let pad: CGFloat = 10

            // MARK: The runway

            let strip = CGRect(x: 18, y: pad,
                               width: halfWidth * 2, height: size.height - pad * 2)
            let pavement = Path(roundedRect: strip, cornerRadius: 2)
            context.fill(pavement, with: .color(Color.secondary.opacity(0.22)))
            context.stroke(pavement, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)

            var centreline = Path()
            centreline.move(to: CGPoint(x: strip.midX, y: strip.minY + 8))
            centreline.addLine(to: CGPoint(x: strip.midX, y: strip.maxY - 36))
            context.stroke(centreline, with: .color(.white.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))

            // Threshold bars and the designator at the near end, where they are painted. The
            // runway points up, so the threshold you cross is the bottom one.
            var bars = Path()
            for offset in [-11.0, -4.0, 4.0, 11.0] {
                bars.move(to: CGPoint(x: strip.midX + offset, y: strip.maxY - 4))
                bars.addLine(to: CGPoint(x: strip.midX + offset, y: strip.maxY - 15))
            }
            context.stroke(bars, with: .color(.white.opacity(0.4)), lineWidth: 2)

            context.draw(Text(selected.runway)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ngAccentText),
                         at: CGPoint(x: strip.midX, y: strip.maxY - 27))

            // MARK: The wind, as its two components

            let left = strip.maxX + 20
            let middle = CGPoint(x: (left + size.width - 12) / 2, y: size.height / 2)
            // The scale a full-strength wind would draw at. Each arrow is that times its own
            // share, so the two are to scale against each other.
            let full = min(size.height / 2 - 14, middle.x - left - 12)
            let knots = max(selected.speed, 1)

            let along = full * selected.headwind / knots
            let across = full * selected.crosswind / knots * (selected.fromRight ? -1 : 1)
            // Both arrows leave one point, since between them they are one vector. That corner
            // is placed so each arrow straddles the middle rather than hanging off it, which
            // keeps the pair centred however the wind swings round.
            let origin = CGPoint(x: middle.x - across / 2, y: middle.y - along / 2)

            func arrow(to tip: CGPoint, from start: CGPoint, colour: Color) {
                var shaft = Path()
                shaft.move(to: start)
                shaft.addLine(to: tip)
                context.stroke(shaft, with: .color(colour),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                let heading = atan2(tip.x - start.x, start.y - tip.y)
                var barbs = Path()
                for spread in [-0.45, 0.45] {
                    barbs.move(to: tip)
                    barbs.addLine(to: CGPoint(x: tip.x - sin(heading + spread) * 8,
                                              y: tip.y + cos(heading + spread) * 8))
                }
                context.stroke(barbs, with: .color(colour),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // Along the runway. A headwind blows from the far end back towards the threshold,
            // so it points down the page; a tailwind points up it.
            if abs(along) >= 1 {
                let tip = CGPoint(x: origin.x, y: origin.y + along)
                let colour = selected.isTailwind ? Color.orange : Color.ngAccentText
                arrow(to: tip, from: origin, colour: colour)
                // Beyond the arrowhead rather than beside the shaft. A strong crosswind pushes
                // the corner of the pair out to the edge, and a label set beside the shaft
                // there had to be clamped back on top of it — which cut the first character
                // off against the arrow.
                let head = along > 0
                context.draw(Text(selected.shortHeadwind)
                    .font(.ngSmallMedium)
                    .foregroundStyle(colour),
                             at: CGPoint(x: min(max(origin.x, 34), size.width - 34),
                                         y: tip.y + (head ? 11 : -11)),
                             anchor: head ? .top : .bottom)
            }

            // Across it, blowing towards the side it pushes you.
            if abs(across) >= 1 {
                let tip = CGPoint(x: origin.x + across, y: origin.y)
                arrow(to: tip, from: origin, colour: Color.ngAccentText)
                // Clear of the along arrow by sitting on the other side of the line from it.
                let below = along < 0
                context.draw(Text(selected.crosswindTag)
                    .font(.ngSmallMedium)
                    .foregroundStyle(Color.ngAccentText),
                             at: CGPoint(x: (origin.x + tip.x) / 2,
                                         y: origin.y + (below ? 9 : -9)),
                             anchor: below ? .top : .bottom)

                if let gust = selected.gustCrosswind, gust >= selected.crosswind + 1 {
                    context.draw(Text("gust \(Int(gust.rounded()))")
                        .font(.ngSmall)
                        .foregroundStyle(Color.orange),
                                 at: CGPoint(x: (origin.x + tip.x) / 2,
                                             y: origin.y + (below ? 22 : -22)),
                                 anchor: below ? .top : .bottom)
                }
            }
        }
    }
}

// MARK: - The resize grip

/// The drag strip along the top of the panel.
///
/// AppKit rather than a SwiftUI `DragGesture` because the window is movable by its background:
/// `mouseDownCanMoveWindow` is the only way to say that a drag here resizes the panel rather
/// than dragging the window, and a cursor rect is the only way to get the resize cursor without
/// pushing and popping one on every hover.
private struct PanelResizeGrip: NSViewRepresentable {

    let onBegin: () -> Void
    /// Points dragged since the drag began, positive upwards.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> Strip {
        let strip = Strip()
        strip.handlers = (onBegin, onDrag, onEnd)
        return strip
    }

    func updateNSView(_ strip: Strip, context: Context) {
        strip.handlers = (onBegin, onDrag, onEnd)
    }

    final class Strip: NSView {

        var handlers: (begin: () -> Void, drag: (CGFloat) -> Void, end: () -> Void)?

        private var startY: CGFloat = 0
        private var isDragging = false
        private var isHovering = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeInActiveApp],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            isHovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            begin()
        }

        override func mouseDragged(with event: NSEvent) {
            // A drag can arrive without the mouse-down that should have preceded it —
            // dismissing a menu eats one — and measuring from a stale origin would make the
            // deltas compound instead of tracking the pointer.
            if !isDragging { begin() }
            // Screen coordinates run upwards, and up is a taller panel.
            handlers?.drag(NSEvent.mouseLocation.y - startY)
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            handlers?.end()
        }

        private func begin() {
            startY = NSEvent.mouseLocation.y
            isDragging = true
            handlers?.begin()
        }

        /// A grip, because a 9-point strip is otherwise invisible and nobody drags what they
        /// cannot see.
        override func draw(_ dirtyRect: NSRect) {
            let grip = NSRect(x: (bounds.width - 26) / 2, y: (bounds.height - 3) / 2,
                              width: 26, height: 3)
            NSColor.secondaryLabelColor
                .withAlphaComponent(isHovering ? 0.8 : 0.45)
                .setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
