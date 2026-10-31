# App Store listing preparation

[Release plan](integration-plan.md) · [Privacy policy](privacy-policy.md)

Prepared copy for the confirmed iPhone, iPad and Mac v1. Nothing has been submitted to App Store Connect. Publish only after the signed build passes the WeatherKit, CloudKit, real-model and device acceptance gates in [launch issue #142](https://github.com/TannerBarcelos/RoamReady/issues/142). Confirm storefront prices and the final policy/support URLs in App Store Connect.

## English (US) copy

| Field | Copy |
| --- | --- |
| Name | RoamReady |
| Subtitle | Camping trips, ready offline |
| Promotional text | Plan your camping trips, personalize setup and teardown checklists, and keep bookings, paperwork, and memories together—even beyond reception. |
| Keywords | camping,rv,camper,checklist,campground,trailer,trip,offline,travel,booking,tent |
| Price | $4.99 USD one-time purchase. No subscription. Set the price in App Store Connect; there are no in-app purchases or unlocks. |
| Support URL | https://github.com/TannerBarcelos/RoamReady/issues |
| Privacy policy URL | https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md — verify it is public after merge, before submission. |

### Description

A little preparation. A lot more camping.

RoamReady brings your rig, camping trips, checklists, paperwork, and memories together on iPhone, iPad, and Mac. Plan at home and keep the essentials with you when reception disappears. No RoamReady account required.

MAKE YOUR RIG FEEL LIKE YOURS
Keep your setup details, photo or emoji, and optional registration information handy. Replace your rig without losing the one recorded on past trips.

ARRIVE WITH A PLAN
Record a booking, campground, dates, site details, and confirmation paperwork. Add check-in times, a booking link, and notes about the site. RoamReady records your reservation; it does not make bookings or show availability.

CHECKLISTS THAT FIT YOUR FLOW
Start with setup and teardown lists tailored to your rig and equipment. Add, edit, reorder, complete, or skip steps. Keep priorities and personal notes separate from general guidance. Each trip gets independent progress, and you choose when to update reusable defaults.

KEEP PAPERWORK AND MEMORIES CLOSE
Save manuals, insurance, registration, and trip confirmations as PDFs or images for offline access. Add campsite photos, captions, notes, and return-or-avoid ratings so your next visit starts with what you learned last time.

EXPLORE WHEN CONNECTED
Find campgrounds and RV parks through Apple Maps, save places to your lists, open their websites, or get directions. Check local weather and trip forecasts, with saved readings available offline.

ASK FOR CAMPING HELP
On devices that support Apple Intelligence, ask Apple's on-device model general camping and checklist questions, and get answers from your own manuals and reservation paperwork (English documents) with the pages it used. Documents are read on your device and never leave it. Apple Intelligence must be enabled and its model ready. Your conversation stays in memory across closing the Assistant and clears when you start a new chat or quit the app. Check generated advice against your rig's manuals; it is not a substitute for qualified assistance.

BUILT FOR YOUR DEVICES
Choose System, Light, or Dark appearance. Optional private iCloud sync keeps your library across your Apple devices. Core planning, checklists, saved documents, and locally available photos work offline. Camp Finder, fresh weather, web links, cloud transfers, and downloading cloud-only files or photos need a connection.

$4.99 one-time purchase. No subscription.

## Assets and account steps still needed

- **Optimized for iPhone Duo:** Apple's [preparation guide](https://developer.apple.com/iphone-duo/prepare/) ties this product-page badge to submitting Duo screenshots in App Store Connect; there is no app-side badge switch. CI already requires the iOS 27.1 SDK or newer. After #142 B14 acceptance on the shipping build, capture outer- and inner-display screenshots following Apple's [specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), upload and preview them in App Store Connect, and verify the badge after release. Duo screenshots become required in April 2027 for apps built with the iOS 27.1 SDK or newer. Keep the launch task unchecked until these steps are complete.
- Privacy label and notices: the Assistant's document indexing is on-device only (no data collected). Settings has no acknowledgements screen, so the sqlite-vec MIT/Apache-2.0 notice lives in the README, the provenance note, and the privacy policy; decide whether the owner wants an in-app screen before submission.

- Choose the final bundle ID and development team, provision the dedicated CloudKit container and WeatherKit, deploy the production schema, and validate the signed archive and checked-in icon.
- Capture actual Release-build screenshots on the required iPhone, iPad and Mac sizes. Useful screens: Home with a current trip, booking/site details, a personalized checklist, memories, and Camp Finder. Use demonstration data and photos you can publish. Do not present simulator AI test replies as real generated responses.
- Complete the App Store age-rating and export-compliance questionnaires using the shipped build. Confirm privacy declarations against the [privacy policy](privacy-policy.md), manifest and actual Apple capabilities; no answers have been submitted here.
- Complete the Paid Apps Agreement, tax/banking information, pricing schedule, TestFlight and review steps in #142. Those require the owner's authorized Apple account.
