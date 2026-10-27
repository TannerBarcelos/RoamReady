# RoamReady

## Building and running in the simulator

Build the `RoamReady` scheme from `RoamReady.xcodeproj` (the other schemes are the Swift packages):

```bash
xcodebuild -project RoamReady.xcodeproj -scheme RoamReady -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

The app's bundle ID is `com.example.RoamReady`. New files under `Camp/` join the app target automatically (the project uses synchronized folders).

## Sample trips for testing

To test layouts with many trips (Home's Next trip and Later sections, trip lists), launch a Debug build with `-seed-sample-trips`:

```bash
xcrun simctl launch booted com.example.RoamReady -seed-sample-trips
```

`Camp/App/SampleTrips.swift` then adds seven trips to the library that's already on the device: five upcoming (from 4 days to about 2.5 months out) and two that ended weeks ago. It uses the first active rig, so a profile and a rig must already exist (finish onboarding first). Some notes:

- It writes to the real on-device library, not an in-memory one, so the trips sync through iCloud if the simulator is signed in. Delete them in the app when you're done.
- Seeded trips have a `SAMPLE-<n>` confirmation number. If any trip already has one, seeding is skipped, so launching again with the flag doesn't add duplicates.
- It's compiled only in Debug builds and does nothing without the flag.
- For isolated fixtures that never touch the owner's library, UI tests use `-navigation-ui-test` (`NavigationUITestLibrary`) instead.
