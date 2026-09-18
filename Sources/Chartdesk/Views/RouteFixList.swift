import SwiftUI

/// The route as a list, in the column where the chart list usually is.
///
/// The map answers "what shape is this flight"; this answers "what am I cleared via", which is
/// the question you have with a chart on the screen. Reading the same navlog, so nothing here
/// needs a navigation database either.
struct RouteFixList: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var flight: FlightPlanStore
    @EnvironmentObject private var navdata: NavDataStore

    private var waypoints: [FlightPlan.Waypoint] { flight.plan?.waypoints ?? [] }

    /// What the procedure demands at a fix, from the navigation data.
    ///
    /// A SID belongs to the origin and a STAR to the destination, and the plan does not say
    /// which of the two a fix came off, so both are asked — a procedure name only matches at
    /// the airport that publishes it. The planned runway goes with the question because the
    /// same fix can carry different restrictions on different runway transitions.
    private func constraint(for waypoint: FlightPlan.Waypoint) -> AltitudeConstraint? {
        guard waypoint.isProcedure,
              let procedure = waypoint.via, procedure != "DCT",
              let plan = flight.plan
        else { return nil }

        for field in plan.airfields where field.role != .alternate {
            if let found = navdata.constraint(for: waypoint.ident,
                                              procedure: procedure,
                                              airport: field.icao,
                                              runway: field.runway) {
                return found
            }
        }
        return nil
    }

    /// A fix and whether its altitude simply repeats the one above.
    ///
    /// A cruise run is a dozen rows of FL360, which is a dozen figures saying one thing. A
    /// restriction is never dittoed, whatever the figure: the point of the magenta and its bars
    /// is that the number is stated, and "same as above" does not state it.
    private var rows: [(waypoint: FlightPlan.Waypoint,
                        constraint: AltitudeConstraint?,
                        repeats: Bool)] {
        var out: [(FlightPlan.Waypoint, AltitudeConstraint?, Bool)] = []
        var previous: Int?
        for waypoint in waypoints {
            let restriction = constraint(for: waypoint)
            let altitude = restriction?.feet ?? waypoint.altitude
            let repeats = restriction == nil && altitude != nil && altitude == previous
            out.append((waypoint, restriction, repeats))
            if let altitude = altitude { previous = altitude }
        }
        return out
    }

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
            ForEach(rows, id: \.waypoint.id) { row in
                let waypoint = row.waypoint
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // One colour per column, not one per kind of fix: idents read as idents,
                    // the airway beside them as secondary, altitudes as the magenta column.
                    // An airport is told apart by weight, which is a difference you can see
                    // without having to learn what a fourth colour meant.
                    Text(waypoint.ident)
                        .font(waypoint.isAirport ? .ngSmallBold : .ngSmall)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
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
                        AltitudeLabel(feet: altitude,
                                      constraint: row.constraint,
                                      repeatsAbove: row.repeats)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

}
