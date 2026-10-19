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

actor WeatherStore {
    static let shared = WeatherStore()
    private let directory = URL.applicationSupportDirectory.appendingPathComponent("Camp/Weather", isDirectory: true)
    private func url(latitude: Double, longitude: Double) -> URL {
        directory.appendingPathComponent("\(latitude)_\(longitude).json")
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url(latitude: latitude, longitude: longitude), options: .atomic)
        return snapshot
    }
}
