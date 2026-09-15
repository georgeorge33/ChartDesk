import SwiftUI

/// Weather for any airport, with the wind drawn against the runways you care about.
///
/// A window rather than another panel: you want this open beside a chart while you decide
/// which runway to ask for, not competing with the chart list for width.
struct WeatherWindow: View {

    @EnvironmentObject private var weather: WeatherStore
    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState

    @State private var query = ""
    @State private var selected: String?

    private var code: String? { weather.lookupICAO }
    private var report: AirportWeather? { weather.weather(for: code) }
    private var wind: WindObservation? { report?.metar.flatMap(WindMath.parse) }

    private var winds: [RunwayWind] {
        guard let wind = wind else { return [] }
        return WindMath.components(wind: wind,
                                   variationWest: weather.variation(for: code),
                                   runways: WindMath.runways(from: weather.runwayList(for: code)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            search
            Divider().overlay(Color.ngSeparator)

            if code == nil {
                hint
            } else {
                windSection
                Divider().overlay(Color.ngSeparator)
                reports
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
        .background(Color.ngWindow)
        .onAppear {
            if weather.lookupICAO == nil {
                let start = library.airport(code: browser.sidebarSelection?.airportCode)?.code
                query = start ?? ""
                if let start = start { weather.lookUp(start) }
            } else {
                query = weather.lookupICAO ?? ""
            }
        }
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: 8) {
            TextField("ICAO", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .onSubmit(lookUp)

            Button("Look up", action: lookUp)
                .disabled(query.trimmingCharacters(in: .whitespaces).count != 4)

            if let code = code {
                Text(code)
                    .font(.headline)
                    .foregroundStyle(Color.ngAccentText)
            }

            Spacer(minLength: 0)

            if let age = weather.age(for: code) {
                Text(age).font(.caption).foregroundStyle(.tertiary)
            }
            if weather.isFetching {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
            } else if code != nil {
                Button {
                    weather.refresh(code)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ngAccentText)
                .help("Fetch the latest")
            }
        }
    }

    private func lookUp() {
        let wanted = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard wanted.count == 4 else { return }
        query = wanted
        selected = nil
        weather.lookUp(wanted)
    }

    private var hint: some View {
        Text("Enter an ICAO code to see its weather.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Wind

    private var windSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(wind?.summary ?? (weather.isFetching ? "Fetching…" : "No wind reported"))
                    .font(.title3)
                Spacer(minLength: 0)
                Text("Variation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: variationBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                Text("°W")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // METAR wind is referenced to true north while runway numbers are magnetic, so
            // without this the answer is quietly wrong by the local variation.
            Text("METAR wind is true; runway numbers are magnetic. Set the variation from the "
                 + "chart (Boston is 15°W) or the components will be off by that much.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 18) {
                WindRose(winds: winds,
                         windFrom: wind?.direction.map { Double($0) + weather.variation(for: code) },
                         highlighted: selected ?? WindMath.best(winds)?.runway)
                    .frame(width: 210, height: 210)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Runways")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("04L 04R 09 22L 22R 27", text: runwayBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    table
                }
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            if winds.isEmpty {
                Text(WindMath.runways(from: weather.runwayList(for: code)).isEmpty
                     ? "Type the runways you use above."
                     : (wind?.isCalm == true ? "Wind is calm — nothing to resolve."
                        : "Wind is variable — no steady direction to resolve."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                let best = WindMath.best(winds)?.runway
                ForEach(winds) { entry in
                    row(entry, isBest: entry.runway == best)
                }
            }
        }
    }

    private func row(_ entry: RunwayWind, isBest: Bool) -> some View {
        let chosen = (selected ?? "") == entry.runway
        return Button {
            selected = chosen ? nil : entry.runway
        } label: {
            HStack(spacing: 8) {
                Text(entry.runway)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 38, alignment: .leading)
                Text(entry.headwindLabel)
                    .foregroundStyle(entry.isTailwind ? Color.orange : Color.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(entry.crosswindLabel)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isBest {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.ngAccentText)
                        .help("Most headwind of the runways listed")
                }
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(chosen ? Color.ngAccent.opacity(0.5) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.gustCrosswind.map {
            "Gusting to \(Int($0.rounded())) kt across" } ?? entry.runway)
    }

    private var variationBinding: Binding<Double> {
        Binding(get: { weather.variation(for: code) },
                set: { weather.setVariation($0, for: code) })
    }

    private var runwayBinding: Binding<String> {
        Binding(get: { weather.runwayList(for: code) },
                set: { weather.setRunwayList($0, for: code) })
    }

    // MARK: Text reports

    private var reports: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let metar = report?.metar { block("METAR", metar, mono: true) }
                if let taf = report?.taf { block("TAF", taf, mono: true) }
                ForEach(report?.realAtis ?? []) { block($0.label, $0.text) }
                ForEach(report?.vatsimAtis ?? []) { block("VATSIM \($0.label)", $0.text) }
                ForEach(report?.notes ?? [], id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func block(_ title: String, _ text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.ngAccentText)
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
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
            let radius = min(size.width, size.height) / 2 - 18

            func point(_ bearing: Double, _ distance: Double) -> CGPoint {
                let radians = bearing * .pi / 180
                return CGPoint(x: centre.x + sin(radians) * distance,
                               y: centre.y - cos(radians) * distance)
            }

            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(Color.ngSeparator), lineWidth: 1)

            for bearing in stride(from: 0.0, to: 360.0, by: 30) {
                var tick = Path()
                tick.move(to: point(bearing, radius - (bearing.truncatingRemainder(dividingBy: 90) == 0 ? 9 : 5)))
                tick.addLine(to: point(bearing, radius))
                context.stroke(tick, with: .color(Color.ngSeparator), lineWidth: 1)
            }

            // Resolved text rather than `.foregroundStyle`, which needs macOS 14 on `Text`.
            var north = context.resolve(Text("N").font(.system(size: 10, weight: .semibold)))
            north.shading = .color(Color.secondary)
            context.draw(north, at: point(0, radius + 10))

            for entry in winds {
                let isChosen = entry.runway == highlighted
                var ray = Path()
                ray.move(to: centre)
                ray.addLine(to: point(Double(entry.magneticHeading), radius - 12))
                context.stroke(ray,
                               with: .color(isChosen ? Color.ngAccentText : Color.secondary.opacity(0.45)),
                               style: StrokeStyle(lineWidth: isChosen ? 5 : 3, lineCap: .round))
                var label = context.resolve(Text(entry.runway)
                    .font(.system(size: 9, weight: isChosen ? .semibold : .regular)))
                label.shading = .color(isChosen ? Color.ngAccentText : Color.secondary)
                context.draw(label, at: point(Double(entry.magneticHeading), radius - 1))
            }

            if let windFrom = windFrom {
                // An arrow from the rim inwards: wind blows *from* its reported bearing.
                let tail = point(windFrom, radius - 2)
                let head = point(windFrom, radius * 0.34)
                var shaft = Path()
                shaft.move(to: tail)
                shaft.addLine(to: head)
                context.stroke(shaft, with: .color(Color.orange),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                let back = windFrom + 180
                var barbs = Path()
                for spread in [-26.0, 26.0] {
                    barbs.move(to: head)
                    let radians = (back + spread) * .pi / 180
                    barbs.addLine(to: CGPoint(x: head.x + sin(radians) * 11,
                                              y: head.y - cos(radians) * 11))
                }
                context.stroke(barbs, with: .color(Color.orange),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }
}
