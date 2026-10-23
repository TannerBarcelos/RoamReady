import SwiftUI
import CoreLocation
import Observation

/// The temperature where the owner is now, at the top right of Home. It asks for location only when
/// tapped the first time, and disappears if location access is off.
struct CurrentWeatherBadge: View {
    @Environment(Connectivity.self) private var connectivity
    @State private var weather = LocalWeather()
    @State private var showingDetails = false

    var body: some View {
        Group {
            if let conditions = weather.conditions, weather.access != .denied {
                Button { showingDetails = true } label: {
                    Label(WeatherFormat.temperature(conditions.temperatureCelsius), systemImage: conditions.symbol)
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.multicolor)
                }
                .accessibilityLabel("Weather here: \(WeatherFormat.temperature(conditions.temperatureCelsius)), \(conditions.condition)")
            } else if weather.access == .unknown {
                Button { Task { await weather.refresh(force: true) } } label: {
                    Image(systemName: "thermometer.medium")
                }
                .accessibilityLabel("Show the weather where you are")
            }
        }
        .sheet(isPresented: $showingDetails) { CurrentWeatherSheet(weather: weather) }
        .task(id: connectivity.isOnline) {
            await weather.load()
            if connectivity.isOnline { await weather.refresh() }
        }
    }
}

struct CurrentWeatherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Connectivity.self) private var connectivity
    let weather: LocalWeather

    var body: some View {
        NavigationStack {
            List {
                if let conditions = weather.conditions {
                    Section {
                        HStack(spacing: 16) {
                            Image(systemName: conditions.symbol).symbolRenderingMode(.multicolor).font(.largeTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(WeatherFormat.temperature(conditions.temperatureCelsius)).font(.largeTitle.bold())
                                Text(conditions.condition).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        if let high = conditions.highCelsius, let low = conditions.lowCelsius {
                            LabeledContent("Today", value: "\(WeatherFormat.temperature(high)) / \(WeatherFormat.temperature(low))")
                        }
                    } footer: {
                        Text("Near your current location · Updated \(conditions.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Section {
                        if let failure = weather.failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                        Button {
                            Task { await weather.refresh(force: true) }
                        } label: {
                            if weather.refreshing { ProgressView("Updating…") }
                            else { Label("Refresh", systemImage: "arrow.clockwise") }
                        }
                        .disabled(weather.refreshing || !connectivity.isOnline)
                    }
                    Section {
                        WeatherAttribution(legalURL: conditions.attributionURL, lightMarkURL: conditions.lightMarkURL,
                                           darkMarkURL: conditions.darkMarkURL)
                    }
                }
            }
            .navigationTitle("Weather here").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Location and current conditions for the badge. The last reading is saved, so it shows offline.
@MainActor @Observable
final class LocalWeather {
    enum Access { case unknown, allowed, denied }

    private(set) var conditions: CurrentConditions?
    private(set) var access: Access
    private(set) var refreshing = false
    private(set) var failure: String?
    @ObservationIgnored private let manager = CLLocationManager()

    init() { access = Self.access(manager.authorizationStatus) }

    func load() async {
        if conditions == nil { conditions = await WeatherStore.shared.cachedCurrent() }
    }

    /// Updates a reading older than 30 minutes. `force` (a tap) also asks for location the first time.
    func refresh(force: Bool = false) async {
        access = Self.access(manager.authorizationStatus)
        guard access != .denied, !refreshing, force || access == .allowed else { return }
        if !force, let conditions, conditions.fetchedAt > .now.addingTimeInterval(-30 * 60) { return }
        refreshing = true
        defer { refreshing = false }
        do {
            guard let location = try await currentLocation() else { return }
            conditions = try await WeatherStore.shared.fetchCurrent(latitude: location.coordinate.latitude,
                                                                    longitude: location.coordinate.longitude)
            failure = nil
        } catch {
            failure = "Couldn’t update the weather. Check your connection and try again."
        }
    }

    /// One location fix. The service session shows the permission prompt if it hasn't been answered.
    private func currentLocation() async throws -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                access = .denied
                return nil
            }
            if let location = update.location {
                access = .allowed
                return location
            }
        }
        return nil
    }

    private static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .unknown
        case .denied, .restricted: .denied
        default: .allowed
        }
    }
}

enum WeatherFormat {
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
