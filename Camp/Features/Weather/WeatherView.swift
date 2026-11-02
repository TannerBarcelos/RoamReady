import SwiftUI
import CampCore

struct WeatherSection: View {
    /// A snapshot of the trip's dates and location, so a trip being added can show weather too.
    let trip: TripDraft
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var forecast: SavedForecast?
    @State private var refreshing = false
    @State private var failure: String?
    var matchingDays: [SavedDayWeather] {
        guard let window = trip.forecastDayWindow else { return [] }
        let calendar = trip.campgroundCalendar
        return forecast?.days.filter {
            window.contains(calendar.startOfDay(for: $0.date))
        } ?? []
    }
    var partialForecast: Bool {
        guard let window = trip.forecastDayWindow, let first = matchingDays.first, let last = matchingDays.last else { return false }
        let calendar = trip.campgroundCalendar
        return calendar.startOfDay(for: first.date) > window.lowerBound || calendar.startOfDay(for: last.date) < window.upperBound
    }
    /// The one note under the forecast: when it was saved, and that it can be out of date.
    var footerText: String? {
        guard let forecast else { return nil }
        let saved = forecast.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        let note = "Forecast saved \(saved). Conditions may have changed."
        return partialForecast && !matchingDays.isEmpty ? note + " Some trip dates aren’t available yet." : note
    }
    func dayLabel(_ date: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = trip.campgroundCalendar.timeZone
        return date.formatted(style)
    }
    var body: some View {
        Section {
            if trip.latitude == nil {
                Text("A location is needed for weather. Choose a campground from Camp Finder when creating your trip.").foregroundStyle(.secondary)
            } else {
                if let forecast {
                    ForEach(matchingDays) { day in
                        forecastLayout {
                            Image(systemName: day.symbol).symbolRenderingMode(.multicolor).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dayLabel(day.date))
                                Text("Rain \(Int(day.precipitationChance * 100))% · Wind \(Measurement(value: day.windKPH, unit: UnitSpeed.kilometersPerHour).formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text("\(WeatherFormat.temperature(day.highCelsius)) / \(WeatherFormat.temperature(day.lowCelsius))").font(.subheadline)
                        }.accessibilityElement(children: .combine)
                    }
                    if matchingDays.isEmpty { Text("These dates are outside the saved forecast window. Check again closer to departure.").foregroundStyle(.secondary) }
                    WeatherAttribution(legalURL: forecast.attributionURL, lightMarkURL: forecast.lightMarkURL,
                                       darkMarkURL: forecast.darkMarkURL)
                } else {
                    Text("No forecast saved yet. Weather needs a connection to refresh and is available only within the provider’s forecast window.").foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                Button {
                    Task { await refresh() }
                } label: {
                    if refreshing { ProgressView("Updating forecast…") }
                    else { Label("Refresh forecast", systemImage: "arrow.clockwise") }
                }.disabled(refreshing)
            }
        } header: {
            Text("Weather")
        } footer: {
            if trip.latitude != nil, let footerText { Text(footerText).accessibilityIdentifier("weatherFooter") }
        }
        .task(id: "\(trip.latitude ?? 0),\(trip.longitude ?? 0)") {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-weather-forecast-fixture") {
                forecast = fixtureForecast()
                return
            }
            #endif
            if let latitude = trip.latitude, let longitude = trip.longitude {
                forecast = await WeatherStore.shared.cached(latitude: latitude, longitude: longitude)
            } else { forecast = nil }
        }
    }
    private var forecastLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
    }

    private func refresh() async {
        guard let latitude = trip.latitude, let longitude = trip.longitude else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            forecast = try await WeatherStore.shared.fetch(latitude: latitude, longitude: longitude)
            failure = nil
        } catch {
            failure = "Couldn’t update weather. Any saved forecast is still available. Check your connection and try again later."
        }
    }

    #if DEBUG
    /// Every trip day except the last, so the partial-forecast note shows. 64.6 °F / 49.7 °F checks rounding.
    private func fixtureForecast() -> SavedForecast? {
        guard let window = trip.forecastDayWindow else { return nil }
        let calendar = trip.campgroundCalendar
        var days: [SavedDayWeather] = []
        var day = window.lowerBound
        while day < window.upperBound {
            days.append(SavedDayWeather(date: day, symbol: "sun.max.fill", condition: "Sunny",
                                        lowCelsius: (49.745479 - 32) * 5 / 9, highCelsius: (64.601352 - 32) * 5 / 9,
                                        precipitationChance: 0.2, windKPH: 14.6))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return SavedForecast(fetchedAt: .now, latitude: trip.latitude ?? 0, longitude: trip.longitude ?? 0, days: days,
                             attributionURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
                             lightMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Light.svg")!,
                             darkMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Dark.svg")!)
    }
    #endif
}
