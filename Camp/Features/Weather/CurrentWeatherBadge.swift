import SwiftUI
import CoreLocation
import Observation

/// A read-only temperature. Only unavailable states offer a permission or retry action.
struct CurrentWeatherBadge: View {
    @Environment(Connectivity.self) private var connectivity
    @Environment(AppPermissions.self) private var permissions
    let weather: LocalWeather
    let openPermissionHelp: () -> Void

    var body: some View {
        Group {
            if permissions.locationDenied {
                Button(action: openPermissionHelp) {
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Local weather unavailable: location access is off")
                .accessibilityHint("Shows how to enable location access in Settings")
                .accessibilityIdentifier("weatherPermissionRequired")
            } else if permissions.locationAllowed, let conditions = weather.conditions {
                Text(WeatherFormat.currentTemperature(conditions.temperatureCelsius))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .accessibilityLabel("Weather here: \(WeatherFormat.currentTemperature(conditions.temperatureCelsius)), \(conditions.condition)")
                    .accessibilityIdentifier("currentTemperature")
            } else if weather.refreshing || !permissions.hasCheckedOnLaunch {
                ProgressView().accessibilityLabel("Loading local weather")
            } else {
                Button { Task { await weather.refresh(force: true) } } label: {
                    Image(systemName: "thermometer.medium.slash").foregroundStyle(.secondary)
                }
                .disabled(!connectivity.isOnline || !permissions.locationAllowed)
                .accessibilityLabel("Local weather unavailable")
                .accessibilityHint(weather.failure ?? "Try updating the weather")
                .accessibilityIdentifier("weatherUnavailable")
            }
        }
    }
}

/// Location and current conditions for the badge. The last reading is saved, so it shows offline.
@MainActor @Observable
final class LocalWeather {
    private(set) var conditions: CurrentConditions?
    private(set) var refreshing = false
    private(set) var failure: String?
    @ObservationIgnored private let location = LocationProvider()

    func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-weather-ui-test") {
            conditions = CurrentConditions(fetchedAt: .now, temperatureCelsius: 22, symbol: "sun.max.fill",
                condition: "Clear", highCelsius: 24, lowCelsius: 16,
                attributionURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
                lightMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Light.svg")!,
                darkMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Dark.svg")!)
            return
        }
        #endif
        if conditions == nil { conditions = await WeatherStore.shared.cachedCurrent() }
    }

    /// Updates a reading older than 30 minutes. Permission is resolved by the launch checks.
    func refresh(force: Bool = false) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-weather-ui-test") { return }
        #endif
        location.refreshAuthorization()
        guard location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways,
              !refreshing else { return }
        if !force, let conditions, conditions.fetchedAt > .now.addingTimeInterval(-30 * 60) { return }
        refreshing = true
        defer { refreshing = false }
        do {
            guard let location = await location.currentLocation() else {
                failure = "Couldn’t find your location. Try again when location is available."
                return
            }
            conditions = try await WeatherStore.shared.fetchCurrent(latitude: location.coordinate.latitude,
                                                                    longitude: location.coordinate.longitude)
            failure = nil
        } catch {
            failure = "Couldn’t update the weather. Check your connection and try again."
        }
    }
}

enum WeatherFormat {
    /// Home always includes the degree unit, for example "72°F" or "22°C".
    static func currentTemperature(_ celsius: Double) -> String {
        let unit: UnitTemperature = Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
        return Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: unit)
            .formatted(.measurement(width: .narrow, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// In the owner's preferred unit, for example "72°".
    static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius).formatted(.measurement(width: .narrow, usage: .weather))
    }
}

/// The Apple Weather mark and legal link that WeatherKit requires wherever its data is shown.
struct WeatherAttribution: View {
    @Environment(\.colorScheme) private var colorScheme
    let legalURL: URL
    let lightMarkURL: URL
    let darkMarkURL: URL
    var body: some View {
        HStack {
            AsyncImage(url: colorScheme == .dark ? darkMarkURL : lightMarkURL) { image in
                image.resizable().scaledToFit()
            } placeholder: { Label("Weather", systemImage: "apple.logo") }
            .frame(width: 90, height: 20)
            Spacer()
            Link("Data sources", destination: legalURL).font(.caption)
        }
    }
}
