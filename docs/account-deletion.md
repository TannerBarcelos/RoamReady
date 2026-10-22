# Account deletion and the RoamReady Worker (#12)

App Store Review Guideline 5.1.1(v) requires in-app account deletion, and Sign in with Apple counts as an account. Apple's guidance for deleting such an account is to revoke the user's tokens with the Sign in with Apple REST API. That call needs a client secret signed with the team's private key, which can't ship in the app, so revocation runs in RoamReady's only v1 server component: a Cloudflare Worker in [`worker/`](../worker).

## Order of operations (app)

Profile › Apple Account › **Delete account** (`DeleteAccountView`, `AccountDeletion`):

1. The screen lists everything that is erased. The owner confirms ("I understand this can't be undone") and then confirms with Sign in with Apple, which returns a fresh identity token and authorization code. The Apple user must be the library's pinned owner.
2. **Revoke**: `POST <RoamReadyAccountServiceURL>/v1/account/revoke`. Any failure stops here, and nothing has changed.
3. **iCloud**: the Core Data mirroring zone (`com.apple.coredata.cloudkit.zone`) is deleted from the app's private CloudKit database. This step is skipped when the build has no container. If iCloud isn't signed in, the flow stops and asks the owner to sign in.
4. **This device**: the library closes, then the `Camp` directory (Core Data stores, backups, Media, forecast cache), the document caches and imports, stored preferences, the Keychain session, and the pinned owner are deleted. The app returns to the sign-in screen.

A failure names the step and stops, so the account is never half-deleted while looking finished. Deletion is blocked offline ("Deleting your account needs a connection"). Other devices signed in to the same iCloud account see the zone removed: sync turns off (`ReplicationError.cloudLibraryRemoved`) and their local copy stays until the app is deleted there.

The entry point is hidden unless `RoamReadyAccountServiceURL` in `Info.plist` is an `https` URL. It is empty in development builds.

## Worker

| | |
|---|---|
| Endpoint | `POST /v1/account/revoke`, JSON `{"identityToken", "authorizationCode"}` |
| Caller check | Identity token signature against Apple's keys (`https://appleid.apple.com/auth/keys`, cached and refreshed by `jose`), `iss`, `aud` = bundle ID, expiry, and issued within the last 10 minutes. The authorization code's `id_token` must have the same `sub`, so a caller can only revoke their own access. |
| Apple calls | `/auth/token` (exchange the code), then `/auth/revoke` (`token_type_hint=refresh_token`) |
| Client secret | ES256 JWT (`kid` = key ID, `iss` = team ID, `sub` = bundle ID, `aud` = `https://appleid.apple.com`), signed per request with WebCrypto and valid for 5 minutes |
| Responses | `200 {"revoked": true}`. Errors are `{"error", "message"}`: `400 invalid_request`, `400 invalid_authorization_code`, `401 invalid_identity_token`, `401 identity_mismatch`, `413 too_large`, `500 not_configured`, `502 apple_unavailable` |
| Storage | None. Logs carry error codes only, never tokens, codes, or keys. |

App Attest isn't required in v1 because the endpoint only acts on the caller's own Apple-verified identity. v2 adds App Attest together with the AI proxy (#34).

### Setup

1. Apple Developer › Keys: create a key with **Sign in with Apple** enabled for the App ID (#6). Download `AuthKey_<KEYID>.p8` once, and note the key ID and team ID.
2. In `worker/wrangler.toml`, set `APPLE_BUNDLE_ID`, `APPLE_TEAM_ID`, and `APPLE_KEY_ID` for `staging` and `production`. Until they're set, the Worker answers `500 not_configured`.
3. `cd worker && npm ci`, then `npx wrangler login`, then for each environment run `npx wrangler secret put APPLE_PRIVATE_KEY --env staging` (paste the `.p8` contents). Don't commit the file; `.gitignore` excludes `*.p8`.
4. Deploy with Actions › **Worker** › Run workflow (`staging` or `production`). This needs the `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` secrets on GitHub environments of the same names, and the test job must pass first. Locally, `npm run deploy:staging` does the same.
5. Set `RoamReadyAccountServiceURL` in the app's `Info.plist` (or per build configuration) to the deployed Worker URL.

### Rotating the Apple key

1. Create a second Sign in with Apple key in the developer portal. Both stay valid until one is revoked.
2. `wrangler secret put APPLE_PRIVATE_KEY --env staging`, update `APPLE_KEY_ID`, deploy, and run one deletion against a test account.
3. Repeat for production, then revoke the old key in the portal.

### Development

`npm test` runs the Worker tests with Node's built-in test runner, using generated RSA (Apple) and P-256 (team) keys. `npm run typecheck` runs TypeScript. CI runs both, plus a Wrangler dry-run bundle, on every pull request that touches `worker/`.

## Retention policy for deleted records (proposed; needs product sign-off)

Deletions are soft: a row is marked `removed`, and that flag syncs, so a stale offline edit can never bring a deleted trip back (`testSoftDeleteWinsOverStaleEditAndFavoriteCanBeSavedAgain`). If a tombstone were hard-deleted, a device returning from weeks in the backcountry with an offline edit to that record would re-upload it as new. So:

- **Keep tombstones (identity plus the `removed` flag) indefinitely.** They are a few bytes each. Pruning them is the only way a deleted trip can return.
- **Clear personal content when a record is deleted, not later.** A deleted trip's note text and all of its note revisions are cleared and tombstoned in the same save (#28). Photo bytes are purged when their last reference goes. Document content rows are deleted with an identity-only tombstone.
- **Note revisions of live trips:** proposed to keep the 50 most recent per trip, pruning older ones on save. Not implemented yet; this needs a decision.
- Account deletion removes everything, tombstones included, locally and in iCloud.
