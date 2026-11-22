import Foundation

/// The World Magnetic Model: which way a compass points, anywhere on earth, in the years the
/// model covers.
///
/// NOAA and the British Geological Survey issue it every five years as a file of coefficients,
/// `WMM.COF`, bundled here exactly as NOAA publishes it: a sum of spherical harmonics to degree
/// twelve, each term with the rate it is drifting at. This is that sum as the model's technical
/// report sets it out, cut down to the one figure the app needs — the declination, which a chart
/// calls the variation.
///
/// Foundation and nothing else, so it can be built on its own and checked against the test
/// values NOAA publishes with each model.
struct MagneticModel {

    /// "WMM-2025", from the file's first line.
    let name: String
    /// The year the coefficients are for. Each drifts from here at its own yearly rate.
    let epoch: Double

    private static let degree = 12
    private static let size = degree + 1

    /// The Gauss coefficients and their yearly rates, in nanotesla, indexed `n * size + m`.
    private let g: [Double], h: [Double], gRate: [Double], hRate: [Double]

    /// What turns Gauss-normalised Legendre functions into the Schmidt semi-normalised ones the
    /// coefficients are for. The same for every place, so worked out once.
    private let schmidt: [Double]

    /// Reads a coefficient file: a header of epoch, name and date, then one line per term —
    /// n, m, g, h, and the yearly rates of g and h.
    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: " "), header.count >= 2,
              let epoch = Double(header[0]) else { return nil }
        self.epoch = epoch
        name = String(header[1])

        let size = Self.size
        var g = [Double](repeating: 0, count: size * size)
        var h = g, gRate = g, hRate = g
        var terms = 0
        for line in lines.dropFirst() {
            // The file ends in two lines of nines, which are not terms.
            let fields = line.split(separator: " ")
            guard fields.count >= 6, let n = Int(fields[0]), let m = Int(fields[1]),
                  (1...Self.degree).contains(n), (0...n).contains(m),
                  let gnm = Double(fields[2]), let hnm = Double(fields[3]),
                  let gDot = Double(fields[4]), let hDot = Double(fields[5])
            else { continue }
            let index = n * size + m
            g[index] = gnm
            h[index] = hnm
            gRate[index] = gDot
            hRate[index] = hDot
            terms += 1
        }
        // Every term from 1,0 to 12,12 — ninety of them — or the file is not the model.
        guard terms == (2...size).reduce(0, +) else { return nil }
        self.g = g
        self.h = h
        self.gRate = gRate
        self.hRate = hRate

        var schmidt = [Double](repeating: 0, count: size * size)
        schmidt[0] = 1
        for n in 1...Self.degree {
            schmidt[n * size] = schmidt[(n - 1) * size] * Double(2 * n - 1) / Double(n)
            for m in 1...n {
                let factor = Double((n - m + 1) * (m == 1 ? 2 : 1)) / Double(n + m)
                schmidt[n * size + m] = schmidt[n * size + m - 1] * factor.squareRoot()
            }
        }
        self.schmidt = schmidt
    }

    /// The declination at a place and time: degrees east of true north, so negative where a
    /// compass points west of it, as it does across Europe and the eastern United States.
    ///
    /// `latitude` and `longitude` are WGS 84, `altitude` is kilometres above its ellipsoid,
    /// and `year` is a decimal year — 2026.5 is the start of July 2026. Nil at either
    /// geographic pole, where there is no east to measure from.
    func declination(latitude: Double, longitude: Double, altitude: Double = 0,
                     year: Double) -> Double? {
        let size = Self.size

        // From the ellipsoid to a sphere: the model is a potential about the earth's centre.
        let semiMajor = 6378.137, flattening = 1 / 298.257223563
        let eccentricity2 = flattening * (2 - flattening)
        let φ = latitude * .pi / 180, λ = longitude * .pi / 180
        let curvature = semiMajor / (1 - eccentricity2 * sin(φ) * sin(φ)).squareRoot()
        let p = (curvature + altitude) * cos(φ)
        let z = (curvature * (1 - eccentricity2) + altitude) * sin(φ)
        let r = (p * p + z * z).squareRoot()
        let φc = asin(z / r)

        // In colatitude, which the Legendre functions are written in.
        let cosθ = sin(φc), sinθ = cos(φc)
        guard sinθ > 1e-10 else { return nil }

        // The associated Legendre functions and their derivatives in colatitude, by the usual
        // recursion, Gauss-normalised until the Schmidt factors are applied below.
        var P = [Double](repeating: 0, count: size * size)
        var dP = P
        P[0] = 1
        for n in 1...Self.degree {
            for m in 0...n {
                let here = n * size + m, above = (n - 1) * size + m
                if n == m {
                    let diagonal = (n - 1) * size + m - 1
                    P[here] = sinθ * P[diagonal]
                    dP[here] = sinθ * dP[diagonal] + cosθ * P[diagonal]
                } else if n == 1 {
                    P[here] = cosθ * P[above]
                    dP[here] = cosθ * dP[above] - sinθ * P[above]
                } else {
                    // Two rows up has no term at m = n − 1, and nothing is taken from it there.
                    let twoAbove = (n - 2) * size + m
                    let k = m > n - 2
                        ? 0 : Double((n - 1) * (n - 1) - m * m) / Double((2 * n - 1) * (2 * n - 3))
                    P[here] = cosθ * P[above] - k * P[twoAbove]
                    dP[here] = cosθ * dP[above] - sinθ * P[above] - k * dP[twoAbove]
                }
            }
        }

        var cosines = [Double](repeating: 1, count: size), sines = [Double](repeating: 0, count: size)
        for m in 1...Self.degree {
            cosines[m] = cos(Double(m) * λ)
            sines[m] = sin(Double(m) * λ)
        }

        // The field's north, east and down components about the earth's centre.
        let years = year - epoch
        let reference = 6371.2
        var radial = (reference / r) * (reference / r)
        var north = 0.0, east = 0.0, down = 0.0
        for n in 1...Self.degree {
            radial *= reference / r
            for m in 0...n {
                let index = n * size + m
                let gnm = g[index] + years * gRate[index]
                let hnm = h[index] + years * hRate[index]
                let along = gnm * cosines[m] + hnm * sines[m]
                let across = gnm * sines[m] - hnm * cosines[m]
                north += radial * along * dP[index] * schmidt[index]
                east += radial * Double(m) * across * P[index] * schmidt[index]
                down -= radial * Double(n + 1) * along * P[index] * schmidt[index]
            }
        }
        east /= sinθ

        // Back to the ellipsoid's own north, which leans from the centre's by φc − φ.
        let lean = φc - φ
        let northOnEllipsoid = north * cos(lean) - down * sin(lean)
        return atan2(east, northOnEllipsoid) * 180 / .pi
    }

    /// A date as the decimal year the model works in.
    static func decimalYear(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let year = calendar.component(.year, from: date)
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return Double(year) }
        return Double(year) + date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}
