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
    private var report: AirportWeather? { weather.weather(for: code) }
    private var wind: WindObservation? { report?.metar.flatMap(WindMath.parse) }

    private var chartRunways: [String] {
        library.airport(code: code)?.charts.compactMap(\.runway) ?? []
    }

    /// What this airport is known to have, from the charts you hold rather than typed.
    private var knownRunways: [String] {
        WindMath.candidates(fromCharts: chartRunways, remembered: weather.runwayList(for: code))
    }

    /// What the menu offers: every designator when the library knows nothing about the airport,
    /// which is the case for one typed into the field.
    ///
    /// Deliberately not derived from `runways` — that includes whatever is picked, so choosing
    /// 18 at an unknown airport would leave 18 as the only thing left in the menu.
    private var choices: [String] {
        knownRunways.isEmpty ? WindMath.allDesignators : knownRunways
    }

    /// The runways to resolve the wind against: the known ones, plus whatever was picked out of
    /// the full list when there are none.
    private var runways: [String] {
        WindMath.candidates(fromCharts: chartRunways,
                            remembered: weather.runwayList(for: code),
                            including: picked)
    }

    private var winds: [RunwayWind] {
        guard let wind = wind else { return [] }
        return WindMath.components(wind: wind,
                                   variationWest: weather.variation(for: code),
                                   runways: runways)
    }

    /// The runway the diagram is drawn for. Whatever you chose, or the one most into wind until
    /// you do. Falls back when a chosen runway is no longer on the list.
    private var selectedRunway: RunwayWind? {
        winds.first { $0.runway == picked } ?? WindMath.best(winds)
    }

    /// Optional, so an airport we know no runways for shows a placeholder rather than
    /// volunteering 01 as though it were a real answer.
    private var runwayChoice: Binding<String?> {
        Binding(get: { picked ?? selectedRunway?.runway ?? knownRunways.first },
                set: { picked = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if weather.isExpanded { resizeHandle }
            header
            if weather.isExpanded {
                Divider().overlay(Color.ngSeparator)
                content
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
                        .font(.system(size: 9, weight: .semibold))
                    Text("Weather")
                        .font(.caption.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if weather.isExpanded {
                // Typed rather than fixed to the selection, so weather for a destination you
                // hold no charts for is still one field away.
                TextField("ICAO", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 66)
                    .onSubmit(lookUp)
            } else if let code = code {
                Text(code).font(.caption).foregroundStyle(Color.ngAccentText)
            }

            Spacer(minLength: 0)

            if let age = weather.age(for: code), weather.isExpanded {
                Text(age).font(.caption2).foregroundStyle(.tertiary)
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
        .font(.caption)
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

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = weather.problem {
                    Text(problem).font(.caption).foregroundStyle(Color.orange)
                } else if report == nil {
                    Text(weather.isFetching ? "Fetching…" : "No weather loaded.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if report != nil { windSection }

                if let report = report {
                    // METAR and TAF above ATIS: a full ATIS runs to ten lines of hold-short
                    // and crane advisories and would push them out of view.
                    if let metar = report.metar { block("METAR", metar, mono: true) }
                    if let taf = report.taf { block("TAF", taf, mono: true) }
                    ForEach(report.realAtis) { block($0.label, $0.text) }
                    ForEach(report.vatsimAtis) {
                        block("VATSIM \($0.label)", $0.text,
                              accent: Color(nsColor: Theme.category(.arrival)))
                    }
                    ForEach(report.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption2)
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
    private var windSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(wind?.summary ?? "No wind reported")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text("var")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("", value: variationBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 40)
                Text("°W")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("RWY")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: runwayChoice) {
                    if runwayChoice.wrappedValue == nil {
                        Text("—").tag(String?.none)
                    }
                    ForEach(choices, id: \.self) { runway in
                        Text(runway).tag(String?.some(runway))
                    }
                }
                .labelsHidden()
                .font(.caption)
                .frame(width: 84)
                Spacer(minLength: 0)
            }

            // Between the field and the rows: the two settings sit together at the top, and
            // the picture sits directly above the list that picks what it draws.
            if let selected = selectedRunway {
                RunwayWindDiagram(selected: selected)
                    .frame(height: 162)
                    .frame(maxWidth: .infinity)
            }

            if winds.isEmpty {
                Text(runways.isEmpty
                     ? "Pick a runway and the wind will be resolved against it."
                     : (wind == nil
                        ? "No wind in the report — nothing to resolve."
                        : (wind?.isCalm == true
                           ? "Wind is calm — nothing to resolve."
                           : "Wind is variable — no steady direction to resolve.")))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let best = WindMath.best(winds)?.runway
                ForEach(winds) { entry in
                    row(entry, isBest: entry.runway == best)
                }
                // METAR wind is true north, runway numbers are magnetic. Without the variation
                // the components are quietly wrong by exactly that much.
                Text("METAR wind is true, runway numbers are magnetic — set the variation from "
                     + "the chart. The star is the most headwind of these, not what ATC will give you.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: RunwayWind, isBest: Bool) -> some View {
        // Compare against the resolved selection, not `picked`, so the highlighted row is
        // always the runway the diagram is drawing.
        let chosen = selectedRunway?.runway == entry.runway
        return Button {
            picked = chosen ? nil : entry.runway
        } label: {
            HStack(spacing: 7) {
                Text(entry.runway)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 30, alignment: .leading)
                Text(entry.shortHeadwind)
                    .foregroundStyle(entry.isTailwind ? Color.orange : Color.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(entry.shortCrosswind)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isBest {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.ngAccentText)
                }
            }
            .font(.caption)
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

    private func block(_ title: String,
                       _ text: String,
                       accent: Color = Color.ngAccentText,
                       mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(text)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                context.draw(Text(selected.shortHeadwind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colour),
                             at: CGPoint(x: min(origin.x + 9, size.width - 54),
                                         y: (origin.y + tip.y) / 2),
                             anchor: .leading)
            }

            // Across it, blowing towards the side it pushes you.
            if abs(across) >= 1 {
                let tip = CGPoint(x: origin.x + across, y: origin.y)
                arrow(to: tip, from: origin, colour: Color.ngAccentText)
                // Clear of the along arrow by sitting on the other side of the line from it.
                let below = along < 0
                context.draw(Text(selected.crosswindTag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.ngAccentText),
                             at: CGPoint(x: (origin.x + tip.x) / 2,
                                         y: origin.y + (below ? 9 : -9)),
                             anchor: below ? .top : .bottom)

                if let gust = selected.gustCrosswind, gust >= selected.crosswind + 1 {
                    context.draw(Text("gust \(Int(gust.rounded()))")
                        .font(.system(size: 9))
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
