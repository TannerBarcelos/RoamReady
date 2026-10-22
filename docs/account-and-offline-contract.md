# Account, connectivity, and AI contract

## Product behavior

First use requires internet, native Sign in with Apple authorization, and completion of rig/profile onboarding. Downloading from the App Store does not establish a session or prove a connection will exist when the app is opened. There is no guest bypass.

After successful setup, the persisted device session opens the pinned user's local library without a remote token refresh. Saved/planned trips, setup/teardown checklists, progress, edits, notes, ratings, imported photos, and camera capture save through Core Data offline. Photo capture/import remains available even if no iCloud connection is possible. Cached forecasts retain their retrieval time; fresh weather needs connectivity. Manual trip creation from known details remains local; campground discovery requires online access.

Camp Finder and individual-site browsing, initial onboarding, profile/rig changes, account changes, and iCloud preference changes require an available network path. A satisfied NWPathMonitor path is a prerequisite, not proof the service is reachable; actual authorization/download errors are surfaced. Existing profile information remains readable offline. Checklist templates and trip-specific workflows remain local.

## Native identity and library ownership

`AccountSession` uses AuthenticationServices, validates the returned authorization state and credential presence, and stores the Apple subject/name/email/sign-in marker in a device-only Keychain item. It does not save identity/authorization tokens. Apple's native result authenticates access to this device's app library; there is no deployed account backend or server-verified app session. That distinction matters before adding protected hosted services.

The library owner is pinned separately in Application Support, so signing out does not let a different Apple identity adopt the saved library. A pre-account development library requires explicit ownership confirmation during first adoption. Multiple account libraries/account switching are not implemented. Keychain errors fail closed without altering camping data.

Credential state is checked when online. Revoked/not-found/transferred authorization locks access; transient failures retain established local access. An auth generation check discards stale asynchronous verification results. Returning users can reopen offline while an established session remains valid locally, but signing out or revoking access requires signing in again online with the same identity.

Voluntary signout drains local writes and refuses to complete if saving failed. Forced revocation immediately hides library UI, then serialized persistence teardown drains writes, removes observers, and closes the managed coordinator. Failed pending changes are retained in memory for same-owner recovery rather than silently cleared; they are still unsaved and cannot survive process termination if the device cannot write. A retained lifecycle queue, transition mutation guards, and generation checks prevent an old load/refresh from repopulating signed-out UI.

Account deletion, Apple token revocation through a backend, server-side account lifecycle, and a full user-requested local/cloud erase workflow are not implemented. The preview says so instead of reporting false deletion success. These remain App Store release requirements where applicable.

## iCloud identity is separate

A Sign in with Apple subject is not a CloudKit user record ID. Core Data mirroring uses the device's iCloud account, independently approved for this library. The approved container-specific record name is device-only metadata; it is never compared to the Sign in with Apple subject.

Before opening a mirrored store, the controller verifies that the current iCloud identity matches the approved one. If unavailable, the app opens locally and retries approval when connectivity returns; it never blocks the pinned user's offline trips. An identity mismatch leaves sync paused and cannot automatically rebind the library. A CKAccountChanged notification schedules mirroring teardown and local-only reopen. Existing app data is not deliberately deleted by this transition.

This is best-effort coordination around Apple's managed lifecycle, not a guarantee that a previously in-flight transfer can be undone. Signout/switch behavior, cache retention, and account separation still require signed, two-device acceptance. Do not claim production account isolation based on source review or simulator compilation alone.

## Apple-only AI

There is no hosted model route, remote fallback, provider secret, or model picker. Camping questions remain on device. The product gate allows iPhone 16-family hardware identifiers (`iPhone17,*`) and later identifier generations, then independently checks `SystemLanguageModel.default.availability`. iPhone 15 Pro is deliberately excluded by product policy even though Apple supports Apple Intelligence on it. iPad, simulator, unknown identifiers, and other devices retain saved guidance without generative help.

A hardware generation alone does not guarantee AI: Apple Intelligence must be enabled, the model must be downloaded/ready, and Apple's language/region/system eligibility rules must permit it. An initial model download needs connectivity; once ready the on-device model can run offline. A future identifier convention change needs policy review rather than an unsupported App Store hardware claim. App Store metadata cannot express an exact minimum iPhone marketing model; the core app can run on otherwise supported devices while its AI feature is gated at runtime.

Answers use relevant saved checklist guidance and decline unsupported specifications or repairs. Imported user notes are reference data, not privileged prompt instructions. Bundled guidance remains available when generation is unavailable, refused, or fails.

## Provisioning and acceptance

Enable Sign in with Apple for the real App ID/team; the default app entitlement now includes it. Unsigned simulator compilation cannot demonstrate successful authentication. Separately provision the new managed CloudKit container and push delivery as documented in offline-storage.md.

Required device acceptance includes first-time online auth, cancellation, offline returning launch, revocation, signout with a failed local write, same-owner reauthentication, rejected different-owner login, restoration to a new device, iCloud changes during imports/exports, real camera permission/capture, and all Foundation Models availability states. No backend or provider account was created automatically during this work.
