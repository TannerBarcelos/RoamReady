import Foundation
import Observation
import CampCore

/// Development snapshot hosting; production can move this public factual dataset to a CDN
/// without changing its schema. Provider API keys are never shipped in the app.
@MainActor @Observable
final class OnlineCampgroundDirectory {
    private(set) var campgrounds = CampgroundLibrary.all
    private(set) var notice = "Loading the federal campground directory…"
    private(set) var loading = false
    private(set) var failure: String?
    @ObservationIgnored private var loaded = false
    static var baseURL: URL? {
        let value = Bundle.main.object(forInfoDictionaryKey: "RoamReadyCampgroundDataURL") as? String ?? ""
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    func load() async {
        guard !loading, !loaded else { return }
        guard let base = Self.baseURL else {
            notice = CampgroundLibrary.notice
            failure = "The online directory isn’t configured. Showing the bundled starter records."
            return
        }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: base.appendingPathComponent("index.json"))
            request.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 15_000_000 else { throw URLError(.badServerResponse) }
            let result = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(CampgroundDirectory.self, from: data) }.value
            guard result.schemaVersion == 1 else { throw CampError.unsupportedSchema(result.schemaVersion) }
            try Task.checkCancellation()
            campgrounds = result.campgrounds; notice = result.coverageNote
            loaded = true; failure = nil
        } catch is CancellationError { }
        catch {
            failure = "The online directory couldn’t be reached. Showing the bundled starter records; retry while connected."
            notice = CampgroundLibrary.notice
        }
    }
}

actor CampsiteDirectory {
    static let shared = CampsiteDirectory()
    private var cache: [Int: CampsiteShard] = [:]
    private var recent: [Int] = []
    func sites(facilityID: String, baseURL: URL) async throws -> [CampsiteSnapshot] {
        let number = CampsiteShard.number(for: facilityID)
        if let value = cache[number] { return value.sitesByFacility[facilityID] ?? [] }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(format: "sites-%02d.json", number)))
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 8_000_000 else { throw URLError(.badServerResponse) }
        let shard = try CampsiteShard.decode(data)
        cache[number] = shard; recent.removeAll { $0 == number }; recent.append(number)
        while recent.count > 2 { cache.removeValue(forKey: recent.removeFirst()) }
        return shard.sitesByFacility[facilityID] ?? []
    }
}
