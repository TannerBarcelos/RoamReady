# Monetization plan (#33)

**Status: draft for decision.** v1 ships with no payments. This document recommends an answer to each question in #33. Every item marked **Decision** is yours to confirm or change before any paid feature is built. Prices are proposals, not research-backed price points.

## Recommendation in one paragraph

Keep everything RoamReady does today **free forever**: trips and bookings, checklists, offline use, on-device Apple AI, Camp Finder, weather, documents, and one rig. Sell one **subscription, "RoamReady Plus"**, because the only candidate with a real per-user running cost is remote AI (#34), and a recurring cost needs recurring revenue. Plus bundles remote AI with the zero-cost extras (additional rigs, and later offline maps if they're licensed), so there's one thing to buy, one entitlement to check, and one paywall to explain. Don't sell a separate one-time "extra rigs" unlock in v2. It adds a second product, a second restore path, and a client-only limit (see the sync edge case below) for a narrow audience.

## Free tier (forever)

| Feature | Why it stays free |
|---|---|
| Trips/bookings, checklists, notes, photos, documents | The core product; zero marginal cost (on device + the user's own iCloud) |
| Offline use everywhere it works today | The product promise |
| On-device Apple AI (#32) | Runs on the user's iPhone; costs us nothing |
| Camp Finder (federal RIDB) and weather | Low hosting cost; WeatherKit has a free monthly allowance (check the current quota under #6) |
| One active rig | `RigPolicy.maxActiveRigs = 1` today |

## Paid: RoamReady Plus (subscription)

| Included | Our cost per user |
|---|---|
| Remote AI models with the model selector (#34) | Real, per question (below) |
| Additional active rigs (raise `RigPolicy.maxActiveRigs`, e.g. to 5) | ~None |
| Later: offline maps (#20), expanded campground coverage (#18) | Storage/licensing, if adopted |

**Decision: price.** Proposed: $2.99/month or $24.99/year, with a 1-week free trial for new subscribers (an introductory offer). The cost math below leaves wide margin even for heavy users on the cheaper model.

### Remote AI cost per question

Claude API list prices, first-party ([current pricing](https://docs.anthropic.com/en/docs/about-claude/pricing); re-check before launch):

| Model | Input $/1M tokens | Output $/1M tokens |
|---|---|---|
| Claude Haiku 5.5 (`claude-haiku-5-5`), prompts up to 100K tokens | $0.10 | $0.50 |
| Claude Sonnet 5.5 (`claude-sonnet-5-5`) | $2.00 | $10.00 |

Assumed question: ~3,000 input tokens (fixed server-side instructions, saved checklist guidance, trip and rig context, and the question) and ~1,000 output tokens (the answer plus thinking, which is billed as output).

| Model | Per question | 100 questions/month | 300 questions/month |
|---|---|---|---|
| Haiku 5.5 | ≈ $0.0008 | ≈ $0.08 | ≈ $0.24 |
| Sonnet 5.5 | ≈ $0.016 | ≈ $1.60 | ≈ $4.80 |

The fixed instruction prefix is identical on every request, so prompt caching cuts the input side further (Sonnet 5.5 cache reads are $0.20/1M). Measure real token usage on staging before setting final quotas.

**Decision: quotas.** Proposed:
- **Free users get no remote AI quota.** The free tier's AI is on-device. A small free quota (e.g. 10 Haiku questions per month) could serve as a trial, but it means every free user needs an authenticated, attested server identity (#34). Revisit after launch.
- **Plus:** 300 questions per month on Haiku 5.5, of which up to 50 may use Sonnet 5.5. At the worst case, ≈ $0.80 + model mix, about $1–2 per heavy user per month.
- **Hard caps (Worker, D1 or a Durable Object, not KV):** a per-user daily cap (e.g. 30), a per-user monthly spend cap (e.g. $3), and a global daily spend cap that alerts and then disables remote AI, falling back to on-device and saved guidance.

### Store mechanics

- **StoreKit 2 in-app purchase is required.** Plus unlocks digital features inside the app, so it must be sold through Apple's in-app purchase.
- **Products:** one subscription group, "RoamReady Plus", with monthly and annual products, plus an introductory free-trial offer for first-time subscribers.
- **Commission:** Apple's Small Business Program (under $1M in annual proceeds) takes 15%. Above that, subscriptions are 30% in the first year and 15% after a year of continuous service. Price with 15% in mind.
- **Family Sharing.** **Decision.** Recommended: on for the annual plan only, which is cheap to allow because the cost is per question and quotas are per Apple ID.
- **Restore purchases:** StoreKit 2 `Transaction.currentEntitlements` on launch, plus a "Restore purchases" button in Profile, as App Review expects.
- **Subscription management link:** `showManageSubscriptions`.

### Entitlement checks

| Feature | Where it's checked |
|---|---|
| Extra rigs (no server) | On device: StoreKit 2 verified `Transaction` (`VerificationResult.verified`). Raising `RigPolicy.maxActiveRigs` reads the entitlement. |
| Remote AI (server) | **The Worker checks it on every request.** The app sends the signed transaction (JWS); the Worker verifies Apple's signature chain and expiry, or queries the App Store Server API. Each verdict is cached briefly in D1. App Store Server Notifications v2 update it on renewal, expiry, refund, and revoke. A client-only check would be bypassable, so it never decides access to a cost-bearing feature. |

### Sync edge case: extra rigs

Two offline devices can each create a rig, and a sync race then yields more active rigs than the policy allows. #28 already handles this: both rigs stay readable, Profile asks the owner to archive one, and `SQLiteStore.save` refuses any save that raises the active count further.

**Decision.** Recommended: **accept it**, with no server verification of rig counts. The excess costs us nothing, can't grow past one extra rig per offline device, and the app nags until it's resolved. Verifying on the server would make rigs depend on the network, which breaks the offline-first rule.

### Legal and listing

- **Subscription terms in the App Store listing and in-app paywall:** price, period, auto-renewal, how to cancel, and links to the Terms of Use (EULA) and privacy policy, as Guideline 3.1.2 requires.
- **Privacy:** remote AI sends questions and trip and rig context to the Worker and the model provider. Update the App Privacy label, `PrivacyInfo.xcprivacy`, and the privacy policy, and add the one-time consent sheet (5.1.2(i)). This is covered in #34.
- **Listing copy:** "On-device AI requires Apple Intelligence" (#32), and "Remote AI with RoamReady Plus".

## Follow-up issues to open once these decisions are confirmed

1. StoreKit 2: Plus subscription group, paywall, restore, entitlement state in the app.
2. Worker: entitlement verification (JWS / App Store Server API), App Store Server Notifications endpoint, D1 schema.
3. Worker: quotas, spend caps, alerting (part of #34).
4. Raise `RigPolicy.maxActiveRigs` for Plus, read from the entitlement.
5. Legal: terms of use, privacy policy update, listing copy.
