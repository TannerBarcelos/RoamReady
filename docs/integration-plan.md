# Next production integrations

## Offline contract

Local onboarding, trip creation, both checklist snapshots, progress, edits, notes, ratings, and locally imported photos must work without an account or connection. Remote calls must not sit in those write paths. Always acknowledge durable local writes separately from cloud delivery.

The current actor-isolated archive store implements that local foundation. SwiftUI reads the in-memory local state; saves are serialized and coalesced, and the previous archive survives failed encoding, validation, or atomic writes. Failed changes stay in memory with an honest save status. No automatic reset occurs after corrupt/newer-format data is encountered.

## Identity and iCloud

Implement Sign in with Apple for backend identity and CloudKit private storage for Apple-account sync independently. The former does not authenticate a different iCloud account or replace CloudKit's account status.

An already signed-in person must be able to use locally available trips without refreshing their remote session. Initial sign-in and recovery require connectivity. People without iCloud keep local use. Changing either identity must isolate its associated remote state; never silently merge another account's trips into the active local library. Offer explicit, reviewed local-data migration where necessary.

Before writing CloudKit adapter code, settle the record contract: separate profile/template/trip/checklist-item/photo records with stable IDs, modification versions, deletion tombstones, and CKAssets for photos. Keep a durable local outbox. Network reachability is a scheduling hint, not proof a request can succeed. Back off on failures and retry on foreground/network changes; iOS background delivery remains opportunistic.

Merge distinct item/photo edits by stable IDs. Preserve conflicting edits to the same field as a recoverable alternate instead of silently overwriting. Delete tombstones must prevent stale offline devices resurrecting deleted trips. Test partial asset uploads, concurrent checklist edits, account sign-out/switch, revoked access, full iCloud storage, and long disconnections. Do not adopt whole-archive last-writer-wins syncing.

## Hosted AI

Keep model selection out of the consumer UI. Use saved guidance and on-device Foundation Models first when supported. A hosted request is an optional fallback when online; its failure must leave saved guidance available.

Use an authenticated backend with verified Sign in with Apple sessions, Keychain session storage on device, per-account/device rate limits, input/output caps, request timeouts, idempotency, and a measurable monthly spend ceiling. Provider keys stay server-side. Benchmark one inexpensive model against actual equipment questions before committing to it; keep the provider behind a backend interface so changing it requires no model picker.

Disclose that a request will leave the device and send only the relevant question, rig/equipment context, and selected guidance. Photos/location/history should not be included by default. Keep evaluation cases for unsupported questions, missing rig manuals, hazardous symptoms, prompt injection in user notes, and fabricated specifications. Source references must distinguish editorial guidance from user-authored notes.

## Data delivery

Obtain actual offline distribution terms and sample coverage matrices before selecting a full rig or campground provider. The separate sourcing reports enumerate candidates and unresolved coverage. Bundle an approved text snapshot, validate schema/identifiers/provenance, and stage signed updates atomically with a known-good fallback. Imagery, manuals, and offline maps each need their own rights and download status.

## Native release gate

Run the checked-in native build script with Xcode and the iOS 27 SDK, then the airplane-mode acceptance pass in `validation.md`. Validate genuine Liquid Glass behavior, light/dark appearance, large text, VoiceOver, Reduce Transparency/Motion, photo-library edge cases, time zones, low storage, and unsupported Foundation Models states. WeatherKit needs App ID provisioning and provider attribution review. A passing portable Swift test suite cannot substitute for this gate.
