import SwiftUI

/// The route as a list, in the column where the chart list usually is.
///
/// The map answers "what shape is this flight"; this answers "what am I cleared via", which is
/// the question you have with a chart on the screen. Reading the same navlog, so nothing here
/// needs a navigation database either.
struct RouteFixList: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var flight: FlightPlanStore

    private var waypoints: [FlightPlan.Waypoint] { flight.plan?.waypoints ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.ngSeparator)

            if waypoints.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 250)
        .background(Color.ngPanel)
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text("Route Map")
                .font(.system(size: 18, weight: .semibold))

            if let plan = flight.plan {
                Text(plan.pair)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(waypoints.count) fixes"
                     + (plan.aircraft.map { " · \($0)" } ?? ""))
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

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Load a SimBrief flight and its route is drawn on the map.")
                .font(.ngSmall)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(library.airports.count) of your airports are on the map either way.")
                .font(.ngSmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(waypoints) { waypoint in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(waypoint.ident)
                        .font(.ngSmallBold)
                        .monospacedDigit()
                        .foregroundStyle(waypoint.isProcedure ? Color.orange
                                         : (waypoint.isAirport ? Color.ngAccentText : .primary))
                        .frame(width: 58, alignment: .leading)

                    // "DCT" is every other leg and says nothing; the airway or procedure name
                    // is the part worth reading.
                    if let via = waypoint.via, via != "DCT" {
                        Text(via)
                            .font(.ngSmall)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if let altitude = waypoint.altitude, altitude > 0 {
                        Text(level(altitude))
                            .font(.ngSmallMono)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// Flight levels above the transition, feet below it — the way a plan reads them.
    private func level(_ altitude: Int) -> String {
        altitude >= 18_000
            ? String(format: "FL%03d", altitude / 100)
            : "\(altitude) ft"
    }
}
