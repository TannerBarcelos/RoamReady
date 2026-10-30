# Production integrations and release plan

[Documentation index](README.md) · [Build and validation](validation.md)

## V1 audit

See the [v1 readiness audit](v1-audit.md) for requirement-by-requirement evidence, defects fixed, and outstanding release gates. On October 27, 2026, the owner confirmed that v1 keeps chat in memory across sheet dismissal and clears it on app quit. Saved sessions from #65 remain separate work; the existing bounded-history and one-retry context-overflow policy stays in v1. The owner also confirmed iPhone, iPad and Mac in v1, and that AI help stays hidden on devices without Apple Intelligence while checklists remain available everywhere.

## Current status

RoamReady is an initial development build. Account-free onboarding, owner-entered rigs, local trip/checklist/document/memory workflows, Apple-only AI eligibility, online Apple Maps campground discovery, and device-local appearance settings are implemented in source. Production Apple provisioning and physical-device acceptance remain outstanding.

The remaining v1 work (decisions, App Store publishing, and simulator/device acceptance) is tracked in [v1 release: publish to the App Store (#6)](https://github.com/TannerBarcelos/RoamReady/issues/6). There is no v1 backend or campground dataset to provision.

CI runs the package tests, including SwiftData tests against real stores, and builds the native app with Xcode 27/iOS 27. Check the [workflow results](https://github.com/TannerBarcelos/RoamReady/actions) for a particular commit; compilation does not establish device acceptance.

Every unexecuted hardware, service, and account gate is listed with its evidence columns in [Remaining release gates](validation.md#remaining-release-gates). Proposed rewrites of #6 and #74 are drafted in [release-tracker-drafts.md](release-tracker-drafts.md) for the owner to apply.

## Identity and offline operation

There is no sign-up, Sign in with Apple, or server account/session service in v1. First launch and onboarding work offline. Local SwiftData saves do not wait for cloud delivery; manual trips, checklists, notes, photos, ratings, profile/rig edits, and reusable defaults remain available locally.

Camp Finder and fresh weather require connectivity. **Erase all data** deletes the CloudKit zone first in configured builds, then the device library. Multiple libraries per device are not planned. See the [identity contract](account-and-offline-contract.md) and [erase process](erase-data.md).

## iCloud provisioning and acceptance

Private CloudKit mirroring is implemented through SwiftData and Apple's `NSPersistentCloudKitContainer`. Apple owns transfers, retries, history, and external binary delivery.

A configured container enables default-on sync at launch, even offline or without an available iCloud account. Apple manages account transitions and reconnection. The onboarding/Profile preference applies on the next app launch; changing it never reopens a live store and deletes neither copy. The default build has no container and stays local-only.

Before release:

- Register and provision a new dedicated Apple CloudKit container and push delivery.
- Generate and deploy the schema.
- Validate two-device edits/conflicts, account changes, interrupted/large attachment transfers, quota failures, and sync toggling.
- Validate full-library erase, local retention, and Apple's cross-account behavior on signed devices.

See [storage setup and release gates](offline-storage.md).

## WeatherKit

Location temperature and per-trip cached forecasts are implemented. Live data requires a provisioned WeatherKit capability on the App ID and signed build. Verify location permission, approximate location behavior, forecast dates/time zones, offline timestamps, and Apple Weather attribution on devices. See [Apple capability configuration](validation.md#apple-capability-configuration).

## On-device camping help

Foundation Models is the only v1 generative provider. Apple's runtime availability alone decides eligibility on iPhone, iPad, and Mac.

Device acceptance must cover disabled/not-ready models, supported languages/regions, unsupported hardware, model refusal/failure, and offline fallback. Initial model readiness/download requires connectivity. Exact identifier policy lives in the [AI contract](account-and-offline-contract.md#apple-only-ai).

Remote models and a model selector are proposed for v2 (#34); no hosted AI or remote question transfer ships in v1.

## Campground discovery

Camp Finder uses Apple Maps (MapKit): a campground/RV park map, Near me, Search this area, typed search, and place details. It requires no server, API key, or owned dataset. Saved lists keep Apple place identifiers; search results remain session-only.

Validate coverage where people camp, tapped map places, optional website/phone/time-zone details, the Apple place card, per-device throttling, location allowed/denied, offline explanations, and retry (#6). The app does not infer prices, hookups, rig compatibility, or booking availability. Offline maps and region-limited offline lists are v2 work (#20).

See [data coverage](campground-data.md) and the [Camp Finder source guide](campground-sourcing.md#to-check-before-release).

## Deferred product work

| Area | Status |
| --- | --- |
| Rig catalog (#29) | Owner entry in v1; future lookup needs a licensed/permitted source and record provenance. Do not invent year ranges or floorplans. |
| Offline maps and regional campground lists (#20) | Not implemented; hosting/licensing and download behavior need design and validation. |
| Remote AI (#34) | Proposed v2 service with its own identity, consent, and cost controls; it must fit the one-time price (no subscription). |
| Pricing | Settled: $4.99 one-time purchase, with no subscription or in-app purchases now or later. See [pricing](monetization.md). |

## Store listing preparation

The [App Store listing preparation](app-store-listing.md) includes copy, URLs and the remaining asset/account steps. The [privacy policy](privacy-policy.md) is checked in and can be used as the public policy URL after this branch is merged. The public repository's issue tracker provides a support contact. Confirm the final App Store privacy answers against the signed build and its actual capabilities; this document does not create an App Store Connect listing or provision Apple services.

## Native release acceptance

The release pass must include:

- iOS 27 build and runtime on physical devices.
- First launch and return access in airplane mode.
- Two-device iCloud delivery, account changes, deletes, and full-library erase.
- Camera permission/capture, photo import and iCloud Photos edge cases.
- Large trip histories, low storage, save failures, and interrupted file transfers.
- Foundation Models eligibility/readiness/fallback and WeatherKit entitlement/attribution.
- VoiceOver, Dynamic Type, reduced motion/transparency, System/Light/Dark appearance and persistence, rotation, and iPad layouts.
- App icon, production identifiers/signing, privacy disclosures, and service configuration.

Use [build and validation](validation.md) for commands and repeatable acceptance steps. Package tests and unsigned simulator builds do not establish production readiness.
