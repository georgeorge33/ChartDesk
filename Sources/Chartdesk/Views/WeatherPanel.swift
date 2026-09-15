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

            if !winds.isEmpty {
                WindRose(winds: winds,
                         windFrom: wind?.direction.map { Double($0) + weather.variation(for: code) },
                         highlighted: picked ?? WindMath.best(winds)?.runway)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 6) {
                Text("RWY")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("04L 04R 09 22L 27", text: runwayBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
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
        let chosen = picked == entry.runway
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

// MARK: - The rose

/// Runways as rays from the centre, with the wind blowing in from the rim. Drawn in magnetic
/// degrees throughout, so the picture and the numbers agree.
private struct WindRose: View {

    let winds: [RunwayWind]
    /// Magnetic bearing the wind is coming *from*.
    let windFrom: Double?
    let highlighted: String?

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 14

            func point(_ bearing: Double, _ distance: Double) -> CGPoint {
                let radians = bearing * .pi / 180
                return CGPoint(x: centre.x + sin(radians) * distance,
                               y: centre.y - cos(radians) * distance)
            }

            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(Color.ngSeparator), lineWidth: 1)

            for bearing in stride(from: 0.0, to: 360.0, by: 30) {
                let length = bearing.truncatingRemainder(dividingBy: 90) == 0 ? 7.0 : 4.0
                var tick = Path()
                tick.move(to: point(bearing, radius - length))
                tick.addLine(to: point(bearing, radius))
                context.stroke(tick, with: .color(Color.ngSeparator), lineWidth: 1)
            }

            context.draw(Text("N")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary),
                         at: point(0, radius + 8))

            for entry in winds {
                let isChosen = entry.runway == highlighted
                var ray = Path()
                ray.move(to: centre)
                ray.addLine(to: point(Double(entry.magneticHeading), radius - 11))
                context.stroke(ray,
                               with: .color(isChosen ? Color.ngAccentText : Color.secondary.opacity(0.4)),
                               style: StrokeStyle(lineWidth: isChosen ? 4 : 2.5, lineCap: .round))
                context.draw(Text(entry.runway)
                    .font(.system(size: 8, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Color.ngAccentText : Color.secondary),
                             at: point(Double(entry.magneticHeading), radius - 1))
            }

            if let windFrom = windFrom {
                // Wind blows *from* its reported bearing, so the arrow comes in from the rim.
                let head = point(windFrom, radius * 0.3)
                var shaft = Path()
                shaft.move(to: point(windFrom, radius - 2))
                shaft.addLine(to: head)
                context.stroke(shaft, with: .color(Color.orange),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))

                var barbs = Path()
                for spread in [-26.0, 26.0] {
                    barbs.move(to: head)
                    let radians = (windFrom + 180 + spread) * .pi / 180
                    barbs.addLine(to: CGPoint(x: head.x + sin(radians) * 9,
                                              y: head.y - cos(radians) * 9))
                }
                context.stroke(barbs, with: .color(Color.orange),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}
