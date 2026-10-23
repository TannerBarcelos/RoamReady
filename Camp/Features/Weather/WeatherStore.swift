import Foundation
import WeatherKit
import CoreLocation

struct SavedDayWeather: Codable, Identifiable, Sendable {
    var date: Date
    var symbol: String
    var condition: String
    var lowCelsius: Double
    var highCelsius: Double
    var precipitationChance: Double
    var windKPH: Double
    var id: Date { date }
}

struct SavedForecast: Codable, Sendable {
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double
    var days: [SavedDayWeather]
    var attributionURL: URL
    var lightMarkURL: URL
    var darkMarkURL: URL
}

/// Conditions where the owner is now, for the reading at the top of Home.
struct CurrentConditions: Codable, Sendable {
    var fetchedAt: Date
    var temperatureCelsius: Double
    var symbol: String
    var condition: String
    var highCelsius: Double?
    var lowCelsius: Double?
    var attributionURL: URL
    var lightMarkURL: URL
    var darkMarkURL: URL
}

actor WeatherStore {
    static let shared = WeatherStore()
    static let directory = URL.applicationSupportDirectory.appending(path: "Weather", directoryHint: .isDirectory)
    private func url(latitude: Double, longitude: Double) -> URL {
        Self.directory.appending(path: "\(latitude)_\(longitude).json")
    }
    func cached(latitude: Double, longitude: Double) -> SavedForecast? {
        guard let data = try? Data(contentsOf: url(latitude: latitude, longitude: longitude)) else { return nil }
        return try? JSONDecoder().decode(SavedForecast.self, from: data)
    }
    func fetch(latitude: Double, longitude: Double) async throws -> SavedForecast {
        let weather = try await WeatherService.shared.weather(for: CLLocation(latitude: latitude, longitude: longitude))
        let attribution = try await WeatherService.shared.attribution
        let snapshot = SavedForecast(fetchedAt: .now, latitude: latitude, longitude: longitude,
            days: weather.dailyForecast.forecast.map {
                SavedDayWeather(date: $0.date, symbol: $0.symbolName, condition: $0.condition.description,
                                lowCelsius: $0.lowTemperature.converted(to: .celsius).value,
                                highCelsius: $0.highTemperature.converted(to: .celsius).value,
                                precipitationChance: $0.precipitationChance,
                                windKPH: $0.wind.speed.converted(to: .kilometersPerHour).value)
            }, attributionURL: attribution.legalPageURL, lightMarkURL: attribution.combinedMarkLightURL,
            darkMarkURL: attribution.combinedMarkDarkURL)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url(latitude: latitude, longitude: longitude), options: .atomic)
        return snapshot
    }

    private var currentURL: URL { Self.directory.appending(path: "current.json") }
    func cachedCurrent() -> CurrentConditions? {
        guard let data = try? Data(contentsOf: currentURL) else { return nil }
        return try? JSONDecoder().decode(CurrentConditions.self, from: data)
    }
    /// Rounds the location to about 1 km before asking Apple Weather; that's plenty for a temperature.
    func fetchCurrent(latitude: Double, longitude: Double) async throws -> CurrentConditions {
        let location = CLLocation(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
        let (current, daily) = try await WeatherService.shared.weather(for: location, including: .current, .daily)
        let attribution = try await WeatherService.shared.attribution
        let today = daily.forecast.first
        let conditions = CurrentConditions(fetchedAt: .now, temperatureCelsius: current.temperature.converted(to: .celsius).value,
            symbol: current.symbolName, condition: current.condition.description,
            highCelsius: today?.highTemperature.converted(to: .celsius).value,
            lowCelsius: today?.lowTemperature.converted(to: .celsius).value,
            attributionURL: attribution.legalPageURL, lightMarkURL: attribution.combinedMarkLightURL,
            darkMarkURL: attribution.combinedMarkDarkURL)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(conditions).write(to: currentURL, options: .atomic)
        return conditions
    }
}
