import SwiftUI

/// Weather and ATIS for the airport on screen, at the foot of the chart list.
///
/// Collapsed it fetches nothing, so closing it stops the traffic rather than hiding it.
struct WeatherPanel: View {

    @EnvironmentObject private var weather: WeatherStore

    let icao: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if weather.isExpanded {
                Divider().overlay(Color.ngSeparator)
                body(for: weather.weather)
            }
        }
        .background(Color.ngPanelRaised)
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

            if let icao = icao {
                Text(icao)
                    .font(.caption)
                    .foregroundStyle(Color.ngAccentText)
            }

            Spacer(minLength: 0)

            if let age = weather.age, weather.isExpanded {
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if weather.isFetching {
                ProgressView().progressViewStyle(.circular).controlSize(.mini)
            } else if weather.isExpanded {
                Button {
                    weather.refresh()
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

    // MARK: Body

    @ViewBuilder
    private func body(for report: AirportWeather?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                if let problem = weather.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                } else if report == nil {
                    Text(weather.isFetching ? "Fetching…" : "No weather loaded.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let report = report {
                    // METAR and TAF first, deliberately. A full ATIS runs to nine or ten lines
                    // of hold-short and crane advisories, which would push the two things you
                    // actually glance at out of view.
                    if let metar = report.metar {
                        block("METAR", metar, accent: .secondary, mono: true)
                    }
                    if let taf = report.taf {
                        block("TAF", taf, accent: .secondary, mono: true)
                    }
                    ForEach(report.realAtis) { atis in
                        block(atis.label, atis.text, accent: Color.ngAccentText)
                    }
                    ForEach(report.vatsimAtis) { atis in
                        block("VATSIM \(atis.label)", atis.text,
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
        .frame(maxHeight: 210)
    }

    private func block(_ title: String,
                       _ text: String,
                       accent: Color,
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
