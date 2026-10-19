# Next production integrations

## Offline contract

Local onboarding, trip creation, both checklist snapshots, progress, edits, notes, ratings, and locally imported photos must work without an account or connection. Remote calls must not sit in those write paths. Always acknowledge durable local writes separately from cloud delivery.

The app now uses Core Data SQLite with incremental field writes and a transactional upload queue. SwiftUI observes a local library projection; failed changes stay in memory with a surfaced save error. Legacy JSON is imported once and retained for recovery. See [storage architecture](offline-storage.md) for the implemented behavior and release gates.

## Identity and iCloud

Implement Sign in with Apple for backend identity and CloudKit private storage for Apple-account sync independently. The former does not authenticate a different iCloud account or replace CloudKit's account status.

An already signed-in person must be able to use locally available trips without refreshing their remote session. Initial sign-in and recovery require connectivity. People without iCloud keep local use. Changing either identity must isolate its associated remote state; never silently merge another account's trips into the active local library. Offer explicit, reviewed local-data migration where necessary.

`NSPersistentCloudKitContainer` now manages private CloudKit mirroring, retries, persistent history, imports, and external binary asset transfers. The default build stays local-only. Configure a new dedicated container and opt in on next launch; do not reuse the previous custom CloudKit schema.

The app retains incremental property edits, logical duplicate reconciliation, note history, soft deletions, and a device-only coherent projection during partial imports. Apple controls transfer timing and concurrent cloud conflict resolution. Device acceptance for account changes, quota, partial transfers, concurrent edits, and offline use remains required. See [offline storage](offline-storage.md) for the implemented contract and migration details.

## Hosted AI

Keep model selection out of the consumer UI. Use saved guidance and on-device Foundation Models first when supported. A hosted request is an optional fallback when online; its failure must leave saved guidance available.

Use an authenticated backend with verified Sign in with Apple sessions, Keychain session storage on device, per-account/device rate limits, input/output caps, request timeouts, idempotency, and a measurable monthly spend ceiling. Provider keys stay server-side. Benchmark one inexpensive model against actual equipment questions before committing to it; keep the provider behind a backend interface so changing it requires no model picker.

Disclose that a request will leave the device and send only the relevant question, rig/equipment context, and selected guidance. Photos/location/history should not be included by default. Keep evaluation cases for unsupported questions, missing rig manuals, hazardous symptoms, prompt injection in user notes, and fabricated specifications. Source references must distinguish editorial guidance from user-authored notes.

## Data delivery

Obtain actual offline distribution terms and sample coverage matrices before selecting a full rig or campground provider. The separate sourcing reports enumerate candidates and unresolved coverage. Bundle an approved text snapshot, validate schema/identifiers/provenance, and stage signed updates atomically with a known-good fallback. Imagery, manuals, and offline maps each need their own rights and download status.

## Native release gate

Run the checked-in native build script with Xcode and the iOS 27 SDK, then the airplane-mode acceptance pass in `validation.md`. Validate genuine Liquid Glass behavior, light/dark appearance, large text, VoiceOver, Reduce Transparency/Motion, photo-library edge cases, time zones, low storage, and unsupported Foundation Models states. WeatherKit needs App ID provisioning and provider attribution review. A passing portable Swift test suite cannot substitute for this gate.
