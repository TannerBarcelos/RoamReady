import SwiftUI
import CampCore

struct WeatherSection: View {
    /// A snapshot of the trip's dates and location, so a trip being added can show weather too.
    let trip: TripDraft
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
                        HStack {
                            Image(systemName: day.symbol).symbolRenderingMode(.multicolor).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dayLabel(day.date))
                                Text("Rain \(Int(day.precipitationChance * 100))% · Wind \(Measurement(value: day.windKPH, unit: UnitSpeed.kilometersPerHour).formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(WeatherFormat.temperature(day.highCelsius)) / \(WeatherFormat.temperature(day.lowCelsius))").font(.subheadline)
                        }.accessibilityElement(children: .combine)
                    }
                    if matchingDays.isEmpty { Text("These dates are outside the saved forecast window. Check again closer to departure.").foregroundStyle(.secondary) }
                    if partialForecast {
                        Text("The saved forecast covers part of your trip. Some dates aren’t available.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Downloaded \(forecast.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · Conditions may have changed")
                        .font(.caption).foregroundStyle(.secondary)
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
        } header: { Text("Weather") }
        .task(id: "\(trip.latitude ?? 0),\(trip.longitude ?? 0)") {
            if let latitude = trip.latitude, let longitude = trip.longitude {
                forecast = await WeatherStore.shared.cached(latitude: latitude, longitude: longitude)
            } else { forecast = nil }
        }
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
}
