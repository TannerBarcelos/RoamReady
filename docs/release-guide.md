# Shipping a release

[Documentation index](README.md)

How to get what's on `main` to TestFlight testers and the App Store. The TestFlight steps come from shipping `0.1.0 (2)` on Nov 2, 2026. The App Store steps haven't been done yet; correct them after the first release.

An agent can do step 1 and read the repo. Everything from step 2 on needs the owner's Apple account: CloudKit Console, a signed Xcode archive, and App Store Connect.

## The order

1. Merge everything to `main` and test it.
2. If the models changed, deploy the CloudKit schema to Production.
3. Archive and upload from Xcode.
4. Release to **Owner Testing** and check it on your phone.
5. Release to **Family & Friends**.
6. For an App Store release, submit for review.

Merging to `main` sends nothing to Apple. A build only leaves your Mac when you upload it from Xcode.

## Two things that catch people out

**Xcode builds and TestFlight builds use different iCloud databases.** They are separate, and fields don't move across on their own.

| Build | Uses |
| --- | --- |
| Run from Xcode onto your phone | CloudKit **Development** |
| TestFlight and App Store | CloudKit **Production** |

A build can work perfectly from Xcode and still fail to sync on TestFlight if the schema wasn't deployed.

**Version and build are different numbers.** The version (`0.1.0`) is the release name people see. The build (`2`) only has to go up with every upload, and Apple rejects a build number it has already seen for that version. A TestFlight update only needs a new build. An App Store release needs a version higher than the last one released.

## 1. Merge and test

Pull the code you're shipping:

```bash
git switch main && git pull
```

Run the checks in [CLAUDE.md](../CLAUDE.md#commands), then test on your phone from Xcode with a signed build. `Config/Local.xcconfig` is already set up for signing.

## 2. Deploy the CloudKit schema, if the models changed

Skip this step if nothing changed under `Sources/CampPersistence/` that adds an attribute or model. To check, compare against the last shipped commit from the [release log](#release-log):

```bash
git diff <last-shipped-commit> HEAD -- Sources/CampPersistence/Models.swift Sources/CampPersistence/LibraryStore.swift
```

Production only accepts additions: new optional attributes and new models. Never rename, retype, or remove an attribute. A deploy can't be undone, and a field can't be removed afterward. See [offline storage](offline-storage.md).

**Create the fields in Development.** A field generally only appears once it has been used.

1. Run a signed build from Xcode on your phone.
2. Use every new feature so each new field gets a real value. A value that saves nothing creates nothing: for example, an ingredient's category of Other is stored as empty, so pick a different one.

**Check them.**

1. Go to [icloud.developer.apple.com](https://icloud.developer.apple.com) and open **CloudKit Database**.
2. Pick the container `iCloud.com.tannerdev.roamready`, and set the environment to **Development**.
3. Under **Schema**, open **Record Types**. A model's record type is `CD_<Model>` and its fields are `CD_<attribute>`, so `DishItem.have` is `CD_have` on `CD_DishItem`.

**Deploy them.**

1. Click **Deploy Schema Changes**, and read the review screen before confirming.
2. Everything new should be listed. Extra system fields and indexes are normal.
3. If anything is marked as removed or changed, or you see a record type you don't recognize, stop and find out why.
4. Click **Deploy**. Existing data isn't affected.
5. Switch the environment to **Production** and confirm a new field or record type is there.

Do this before uploading. If testers get a build first, their new data may not sync until the fields are deployed.

## 3. Archive and upload

1. In Xcode, choose the **RoamReady** scheme, and set the device to **Any iOS Device (arm64)**. **Archive** is greyed out with a simulator selected.
2. Choose **Product › Archive**. When it finishes, the **Organizer** opens with the new archive selected.
3. Click **Distribute App**, then **TestFlight & App Store**. Leave the default options on, including **Manage Version and Build Number** if it appears.
4. Before clicking **Distribute**, check the review screen shows a build number higher than the last upload. The archive and the repo can still say `1`; Xcode raises it for the upload.
5. If Xcode doesn't raise it, or the upload is rejected for a duplicate build, cancel. Then set **Current Project Version** under the target's **Versioning** settings to the next number, and archive again.

Apple then processes the build. `0.1.0 (2)` took a few minutes, but allow up to 30.

## 4. Release to Owner Testing

In [App Store Connect](https://appstoreconnect.apple.com), go to **RoamReady: Camping Planner › TestFlight**. When processing finishes, the build appears under its version with the status **Ready to Submit**.

**A new build joins no group on its own.** Empty Groups is normal.

1. Click the build number, then add **Owner Testing** under its groups. This group doesn't need Apple's review.
2. If the status is **Missing Compliance**, answer the encryption question. `0.1.0 (2)` didn't ask.
3. Install it from the TestFlight app on your phone. Pull down to refresh if it isn't there.
4. Test what changed, and check sync. This is the first time the code runs against Production. Use a second device on the same iCloud account if you have one, or check the iCloud status under **Profile › Settings**.

## 5. Release to Family & Friends

Only after step 4 looks right.

1. Add **Family & Friends** to the build.
2. Fill in **What to Test**. Mention anything testers could lose, such as data removed by an update.
3. Submit it. External groups can need a short **Beta App Review**, often quick but sometimes a day or so, so don't leave it until a deadline.

Testers with automatic updates on in TestFlight get it on their own. Others get a notification and tap **Update**. Crashes and tester screenshots appear under **Feedback** in the TestFlight tab.

## 6. Release on the App Store

Not done yet. Before the first release, work through [#142](https://github.com/TannerBarcelos/RoamReady/issues/142) and [App Store listing preparation](app-store-listing.md), which cover the agreements, pricing, screenshots, privacy label, and age rating.

1. Set a new **Marketing Version** under the target's **Versioning** settings, then archive and upload as in step 3. Test that build on TestFlight first.
2. In App Store Connect, open the **Distribution** tab and create a new version with the same number.
3. Fill in what's new, and select the build.
4. Submit for review. Choose whether it releases automatically on approval or when you say so.
5. Once it's live, check the listing, price, and platforms.

## Release log

Add a row for each upload, so the next release knows what to compare against for step 2.

| Build | Date | Commit | Schema deployed |
| --- | --- | --- | --- |
| `0.1.0 (1)` | Oct 31, 2026 | not recorded | Initial schema |
| `0.1.0 (2)` | Nov 2, 2026 | `d63d902` | `DishItem`: `amountValue`, `unitValue`, `categoryValue`, `have`. `TripMeal`: `hasStructuredAmounts`. `SavedCampground`: `wouldNotGo`, `wouldNotReturn`. New model: `GroceryAmountOverride`. |
