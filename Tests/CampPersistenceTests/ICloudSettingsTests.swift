import Foundation
import Testing
@testable import CampPersistence

@MainActor
struct ICloudSettingsTests {
    private let container = "iCloud.com.example.RoamReady"

    @Test func aPreferenceChangeLeavesTheCurrentSessionAloneAndAppliesNextLaunch() throws {
        let suite = "ICloudSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-account", forKey: "RoamReady.CloudSyncUser")

        let current = ICloudSettings(containerIdentifier: container, defaults: defaults)
        #expect(defaults.object(forKey: "RoamReady.CloudSyncUser") == nil)
        #expect(current.requested && current.enabledForSession)
        #expect(current.containerForSession == container)
        current.setRequested(false)
        #expect(current.hasPendingChange)
        #expect(current.enabledForSession && current.containerForSession == container)

        let next = ICloudSettings(containerIdentifier: container, defaults: defaults)
        #expect(!next.requested && !next.enabledForSession && !next.hasPendingChange)
        #expect(next.containerForSession == nil)
        next.setRequested(true)
        #expect(next.hasPendingChange && next.containerForSession == nil)

        let relaunched = ICloudSettings(containerIdentifier: container, defaults: defaults)
        #expect(relaunched.enabledForSession && !relaunched.hasPendingChange)
        next.setRequested(false)
        #expect(!next.hasPendingChange, "Undoing a pending preference restores the current session setting")
    }

    @Test func unconfiguredBuildsCannotEnableCloudAccess() throws {
        let suite = "ICloudSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "RoamReady.CloudSyncEnabled")
        for identifier in [nil, "", "$(ROAMREADY_MIRRORING_CONTAINER)", "com.example.invalid"] as [String?] {
            let settings = ICloudSettings(containerIdentifier: identifier, defaults: defaults)
            settings.setRequested(true)
            #expect(!settings.configured && !settings.requested && !settings.enabledForSession)
            #expect(settings.containerForSession == nil && !settings.hasPendingChange)
        }
    }

    @Test func activityReportsCompletionsAndErrorsWithoutPromisingGlobalDelivery() throws {
        let suite = "ICloudSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ICloudSettings(containerIdentifier: container, defaults: defaults)
        let finished = Date()

        settings.recordActivity(finished: nil, succeeded: false, message: nil)
        #expect(settings.lastActivity == nil && settings.lastError == nil)
        settings.recordActivity(finished: finished, succeeded: false, message: "Storage is full")
        #expect(settings.lastActivity == nil && settings.lastError == "Storage is full")
        settings.recordActivity(finished: finished, succeeded: true, message: nil)
        #expect(settings.lastActivity == finished && settings.lastError == nil)
        #expect(settings.status == "iCloud manages synchronization automatically")
    }
}
