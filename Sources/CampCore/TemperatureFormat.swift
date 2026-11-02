import Foundation

/// Temperatures shown as whole numbers in the owner's unit. The rounding happens after converting,
/// so 18.1 °C reads "65°" for someone who uses Fahrenheit.
public enum TemperatureFormat {
    public static func preferredUnit(_ locale: Locale = .current) -> UnitTemperature {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    /// For example "65°", or "65°F" when `includeUnit` is true.
    public static func string(celsius: Double, includeUnit: Bool = false, locale: Locale = .current) -> String {
        let measurement = Measurement(value: celsius, unit: UnitTemperature.celsius)
        let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        // The weather usage honors the device's Temperature setting, not just the region.
        guard includeUnit else {
            return measurement.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: whole).locale(locale))
        }
        let unit = preferredUnit(locale)
        let number = measurement.converted(to: unit).value.formatted(whole.locale(locale))
        return number + (unit == .fahrenheit ? "°F" : "°C")
    }
}
