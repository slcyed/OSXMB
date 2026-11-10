import Foundation

enum SeasonalTheme {
    static let variantID = "live-seasonal"
    static let noonBrightness: Float = 238

    struct DateStop {
        let month: Int
        let day: Int
        let name: String
        let color: RGBColor
    }

    static let dateStops: [DateStop] = [
        DateStop(month: 1, day: 15, name: "Khaki", color: RGBColor(r255: 240, g255: 230, b255: 140)),
        DateStop(month: 1, day: 24, name: "Brown", color: RGBColor(r255: 165, g255: 42, b255: 42)),
        DateStop(month: 2, day: 15, name: "Olive Drab", color: RGBColor(r255: 107, g255: 142, b255: 35)),
        DateStop(month: 2, day: 24, name: "Green", color: RGBColor(r255: 0, g255: 128, b255: 0)),
        DateStop(month: 3, day: 15, name: "Pink", color: RGBColor(r255: 255, g255: 192, b255: 203)),
        DateStop(month: 3, day: 24, name: "Hot Pink", color: RGBColor(r255: 255, g255: 105, b255: 180)),
        DateStop(month: 4, day: 15, name: "Silver", color: RGBColor(r255: 192, g255: 192, b255: 192)),
        DateStop(month: 4, day: 24, name: "Green", color: RGBColor(r255: 0, g255: 128, b255: 0)),
        DateStop(month: 5, day: 15, name: "Thistle", color: RGBColor(r255: 216, g255: 191, b255: 216)),
        DateStop(month: 5, day: 24, name: "Purple", color: RGBColor(r255: 128, g255: 0, b255: 128)),
        DateStop(month: 6, day: 15, name: "Light Blue", color: RGBColor(r255: 173, g255: 216, b255: 230)),
        DateStop(month: 6, day: 24, name: "Teal", color: RGBColor(r255: 0, g255: 128, b255: 128)),
        DateStop(month: 7, day: 15, name: "Blue", color: RGBColor(r255: 0, g255: 0, b255: 255)),
        DateStop(month: 7, day: 24, name: "Dark Blue", color: RGBColor(r255: 0, g255: 0, b255: 139)),
        DateStop(month: 8, day: 15, name: "Purple", color: RGBColor(r255: 128, g255: 0, b255: 128)),
        DateStop(month: 8, day: 24, name: "Violet", color: RGBColor(r255: 238, g255: 130, b255: 238)),
        DateStop(month: 9, day: 15, name: "Maroon", color: RGBColor(r255: 128, g255: 0, b255: 0)),
        DateStop(month: 9, day: 24, name: "Khaki", color: RGBColor(r255: 240, g255: 230, b255: 140)),
        DateStop(month: 10, day: 15, name: "Copper", color: RGBColor(r255: 184, g255: 115, b255: 51)),
        DateStop(month: 10, day: 24, name: "Brown", color: RGBColor(r255: 165, g255: 42, b255: 42)),
        DateStop(month: 11, day: 15, name: "Fire Engine Red", color: RGBColor(r255: 206, g255: 32, b255: 41)),
        DateStop(month: 11, day: 24, name: "Red", color: RGBColor(r255: 255, g255: 0, b255: 0)),
        DateStop(month: 12, day: 15, name: "Mauve", color: RGBColor(r255: 224, g255: 176, b255: 255)),
        DateStop(month: 12, day: 24, name: "Silver", color: RGBColor(r255: 192, g255: 192, b255: 192)),
    ]

    static let hourlyBrightness: [Float] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x22, 0x44, 0x66, 0x88, 0xAA, 0xCC,
        0xEE, 0xCC, 0xAA, 0x88, 0x66, 0x44,
        0x22, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    static func now() -> Date {
        if let raw = ProcessInfo.processInfo.environment["OSXMB_THEME_DATE"] {
            if let seconds = TimeInterval(raw) {
                return Date(timeIntervalSince1970: seconds)
            }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return Date()
    }

    static func makeVariant(at date: Date = now()) -> XMBVariant {
        let calendar = Calendar.current
        let (color, colorLabel) = colorAndLabel(at: date, calendar: calendar)
        let (brightness, hour, minute) = brightness(at: date, calendar: calendar)

        let top = RGBColor(color.r * 0.20 * brightness,
                           color.g * 0.20 * brightness,
                           color.b * 0.20 * brightness)
        let bottom = RGBColor(color.r * brightness,
                              color.g * brightness,
                              color.b * brightness)
        let gradient = XMBGradient(angleDeg: 90, start: top.clamped(), end: bottom.clamped())

        var parameters = XMBParameters()
        parameters.colorR = color.r * 255
        parameters.colorG = color.g * 255
        parameters.colorB = color.b * 255
        parameters.reSyntheticDescriptorSeed = 9001

        let timeText = String(format: "%02d:%02d", hour, minute)
        let percent = Int((brightness * 100).rounded())
        let detail = "\(colorLabel) · \(timeText) · \(percent)% brightness"

        return XMBVariant(
            id: variantID,
            name: "Live Seasonal",
            family: "Live",
            month: nil,
            lighting: nil,
            gradient: gradient,
            parameters: parameters,
            detail: detail
        )
    }

    private static func colorAndLabel(at date: Date, calendar: Calendar) -> (RGBColor, String) {
        let year = calendar.component(.year, from: date)
        let yearDays = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
        let current = dayPosition(for: date, calendar: calendar)

        let points: [(position: Double, stop: DateStop)] = dateStops.map { stop in
            let components = DateComponents(year: year, month: stop.month, day: stop.day, hour: 12)
            let stopDate = calendar.date(from: components) ?? date
            let day = Double(calendar.ordinality(of: .day, in: .year, for: stopDate) ?? 1) - 1
            return (day + 0.5, stop)
        }

        guard let first = points.first, let last = points.last else {
            return (RGBColor(0, 0, 0), "Unknown")
        }

        let lower: (position: Double, stop: DateStop)
        let upper: (position: Double, stop: DateStop)

        if current < first.position {
            lower = (last.position - yearDays, last.stop)
            upper = first
        } else if current >= last.position {
            lower = last
            upper = (first.position + yearDays, first.stop)
        } else {
            var index = 0
            while index + 1 < points.count, points[index + 1].position <= current {
                index += 1
            }
            lower = points[index]
            upper = points[index + 1]
        }

        let span = upper.position - lower.position
        let fraction = span > 0 ? Float((current - lower.position) / span) : 0
        let color = RGBColor.mix(lower.stop.color, upper.stop.color, min(max(fraction, 0), 1)).clamped()
        let label: String
        if fraction < 0.02 {
            label = lower.stop.name
        } else if fraction > 0.98 {
            label = upper.stop.name
        } else if lower.stop.name == upper.stop.name {
            label = lower.stop.name
        } else {
            label = "\(lower.stop.name) → \(upper.stop.name)"
        }
        return (color, label)
    }

    private static func brightness(at date: Date, calendar: Calendar) -> (Float, Int, Int) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let fraction = Float(minute) / 60 + Float(second) / 3600
        let current = hourlyBrightness[hour]
        let next = hourlyBrightness[(hour + 1) % hourlyBrightness.count]
        let raw = current + (next - current) * fraction
        return (max(0, min(1, raw / noonBrightness)), hour, minute)
    }

    private static func dayPosition(for date: Date, calendar: Calendar) -> Double {
        let startOfDay = calendar.startOfDay(for: date)
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1) - 1
        let seconds = date.timeIntervalSince(startOfDay)
        return day + max(0, min(1, seconds / 86400))
    }
}
