import Foundation

/// Temperatures shown as whole numbers in the owner's unit. The rounding happens after converting,
/// so 18.1 °C reads "65°" for someone who uses Fahrenheit.
public enum TemperatureFormat {
    public static func preferredUnit(_ locale: Locale = .current) -> UnitTemperature {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    /// For example "65°", or "65°F" when `includeUnit` is true.
    public static func string(celsius: Double, includeUnit: Bool = false, locale: Locale = .current) -> String {
        let unit = preferredUnit(locale)
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: unit).value
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return number + (includeUnit ? (unit == .fahrenheit ? "°F" : "°C") : "°")
    }
}
