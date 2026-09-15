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

    /// The airport the chart list is showing. The panel follows it unless you type another.
    let icao: String?

    @State private var query = ""
    @State private var picked: String?

    private var code: String? { weather.icao }
    private var report: AirportWeather? { weather.weather(for: code) }
    private var wind: WindObservation? { report?.metar.flatMap(WindMath.parse) }

    private var runways: [String] {
        WindMath.runways(from: weather.runwayList(for: code))
    }

    private var winds: [RunwayWind] {
        guard let wind = wind else { return [] }
        return WindMath.components(wind: wind,
                                   variationWest: weather.variation(for: code),
                                   runways: runways)
    }

    /// The runway the diagram is drawn for. Whatever you clicked, or the one most into wind
    /// until you do. Falls back when a picked runway is edited out of the list.
    private var selectedRunway: RunwayWind? {
        winds.first { $0.runway == picked } ?? WindMath.best(winds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if weather.isExpanded {
                Divider().overlay(Color.ngSeparator)
                content
            }
        }
        .background(Color.ngPanelRaised)
        .onAppear { query = code ?? icao ?? "" }
        .onChange(of: weather.icao) { _, newValue in query = newValue ?? "" }
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
        .frame(maxHeight: 380)
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
                TextField("04L 04R 09 22L 27", text: runwayBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            // Between the field and the rows: the two settings sit together at the top, and
            // the picture sits directly above the list that picks what it draws.
            if let selected = selectedRunway {
                RunwayWindDiagram(selected: selected, all: winds)
                    .frame(height: 162)
                    .frame(maxWidth: .infinity)
            }

            if winds.isEmpty {
                Text(runways.isEmpty
                     ? "Type the runways you use and the wind will be resolved against them."
                     : (wind?.isCalm == true
                        ? "Wind is calm — nothing to resolve."
                        : "Wind is variable — no steady direction to resolve."))
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

    private var runwayBinding: Binding<String> {
        Binding(get: { weather.runwayList(for: code) },
                set: { weather.setRunwayList($0, for: code) })
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

/// The wind resolved onto one runway, with that runway always drawn pointing up the page.
///
/// A compass rose makes you do the rotation in your head, and on approach the only thing that
/// matters is the wind *relative to the runway*. So the picture is rotated instead: the selected
/// runway is always vertical, and it is the only one carrying numbers — six designators' worth
/// of labels is what made the rose a puzzle. The others stay as faint rays for the geometry,
/// and the small N is the only thing saying that up the page is no longer north.
///
/// The wind arrow always reaches from the rim, so its length says nothing about speed. This is
/// an angle picture; the knots are on the labels beside the two components.
private struct RunwayWindDiagram: View {

    let selected: RunwayWind
    /// Every runway on the list, for context rays.
    let all: [RunwayWind]

    /// Half the drawn pavement width. Labels are kept clear of it.
    private let halfWidth: CGFloat = 17

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 16

            /// Screen point for an angle measured clockwise from the runway's own heading.
            func point(_ relative: Double, _ distance: CGFloat) -> CGPoint {
                let radians = relative * .pi / 180
                return CGPoint(x: centre.x + sin(radians) * distance,
                               y: centre.y - cos(radians) * distance)
            }

            // The other runways, for the shape of the airfield. Anything collinear with the
            // selected one — its reciprocal, or a parallel — is the same line and adds nothing.
            var drawn: Set<Int> = [selected.magneticHeading]
            for entry in all {
                // Parallels share a heading, so 04L and 04R are one ray rather than two laid
                // on top of each other.
                guard drawn.insert(entry.magneticHeading).inserted else { continue }
                let relative = Double(entry.magneticHeading - selected.magneticHeading)
                guard abs(sin(relative * .pi / 180)) > 0.09 else { continue }
                var ray = Path()
                ray.move(to: centre)
                ray.addLine(to: point(relative, radius - 6))
                context.stroke(ray, with: .color(Color.secondary.opacity(0.3)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // Where north went.
            let north = Double(-selected.magneticHeading)
            var tick = Path()
            tick.move(to: point(north, radius - 5))
            tick.addLine(to: point(north, radius))
            context.stroke(tick, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
            context.draw(Text("N")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary),
                         at: point(north, radius + 8))

            // The pavement, drawn as a strip rather than a ray so the threshold end is obvious.
            let length = radius - 2
            let strip = CGRect(x: centre.x - halfWidth, y: centre.y - length,
                               width: halfWidth * 2, height: length * 2)
            let pavement = Path(roundedRect: strip, cornerRadius: 2)
            context.fill(pavement, with: .color(Color.secondary.opacity(0.22)))
            context.stroke(pavement, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)

            var centreline = Path()
            centreline.move(to: CGPoint(x: centre.x, y: strip.minY + 8))
            centreline.addLine(to: CGPoint(x: centre.x, y: strip.maxY - 36))
            context.stroke(centreline, with: .color(.white.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))

            // Threshold bars and the designator at the near end, where they are painted. The
            // runway points up, so the threshold you cross is the bottom one.
            var bars = Path()
            for offset in [-11.0, -4.0, 4.0, 11.0] {
                bars.move(to: CGPoint(x: centre.x + offset, y: strip.maxY - 4))
                bars.addLine(to: CGPoint(x: centre.x + offset, y: strip.maxY - 15))
            }
            context.stroke(bars, with: .color(.white.opacity(0.4)), lineWidth: 2)

            context.draw(Text(selected.runway)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ngAccentText),
                         at: CGPoint(x: centre.x, y: strip.maxY - 27))

            // The wind, in the runway's own frame: 0 is straight down it, positive off the right
            // side. The two dashed legs are the decomposition of the orange arrow, so they are
            // to scale against each other without any scaling of their own.
            let from = point(selected.windOffset, radius)
            let corner = CGPoint(x: from.x, y: centre.y)

            if abs(selected.headwind) >= 0.5 {
                var leg = Path()
                leg.move(to: from)
                leg.addLine(to: corner)
                context.stroke(leg, with: .color(Color.ngAccentText.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                // Outboard of the leg, except once the crosswind dominates and the leg is
                // short: its top is then the arrow's own tail, so the label crosses to the far
                // side of the runway rather than sitting on it.
                let stub = abs(from.y - centre.y) < 32
                let side: CGFloat = (from.x >= centre.x) == !stub ? 1 : -1
                let clear = stub ? halfWidth + 9 : max(abs(from.x - centre.x) + 7, halfWidth + 9)
                let x = min(max(centre.x + side * clear, 54), size.width - 54)
                context.draw(Text(selected.shortHeadwind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected.isTailwind ? Color.orange : Color.ngAccentText),
                             at: CGPoint(x: x, y: (from.y + corner.y) / 2),
                             anchor: side > 0 ? .leading : .trailing)
            }

            // The across leg, labelled on the opposite side of the centreline from the side
            // the wind comes in on. With a wind close to the runway heading both legs nearly
            // collapse onto that line, and this is what keeps the two numbers off each other.
            if selected.crosswind >= 0.5 {
                var leg = Path()
                leg.move(to: corner)
                leg.addLine(to: centre)
                context.stroke(leg, with: .color(Color.ngAccentText.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                // Centred on the leg, unless that would print it across the pavement, in
                // which case it starts just clear of the edge and runs outwards.
                let midX = (corner.x + centre.x) / 2
                let below = from.y <= centre.y
                let side: CGFloat = corner.x >= centre.x ? 1 : -1
                let tight = abs(midX - centre.x) < halfWidth + 6
                let x = tight ? centre.x + side * (halfWidth + 6) : midX
                let anchor: UnitPoint = tight
                    ? (below ? (side > 0 ? .topLeading : .topTrailing)
                             : (side > 0 ? .bottomLeading : .bottomTrailing))
                    : (below ? .top : .bottom)

                context.draw(Text(selected.crosswindTag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.ngAccentText),
                             at: CGPoint(x: x, y: centre.y + (below ? 5 : -5)),
                             anchor: anchor)

                // The gust crosswind is the number that actually limits you.
                if let gust = selected.gustCrosswind, gust >= selected.crosswind + 1 {
                    context.draw(Text("gust \(Int(gust.rounded()))")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange),
                                 at: CGPoint(x: x, y: centre.y + (below ? 18 : -18)),
                                 anchor: anchor)
                }
            }

            // The wind itself, over the top of everything: it blows *from* its bearing, so the
            // arrow comes in from the rim and the arrowhead lands on the runway.
            var shaft = Path()
            shaft.move(to: from)
            shaft.addLine(to: centre)
            context.stroke(shaft, with: .color(Color.orange),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var barbs = Path()
            for spread in [-24.0, 24.0] {
                barbs.move(to: centre)
                barbs.addLine(to: point(selected.windOffset + spread, 10))
            }
            context.stroke(barbs, with: .color(Color.orange),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }
}
