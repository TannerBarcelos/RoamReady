# App Store listing preparation

[Release plan](integration-plan.md) · [Privacy policy](privacy-policy.md)

Prepared copy for the confirmed iPhone, iPad and Mac v1. Nothing has been submitted to App Store Connect. Publish only after the signed build passes the WeatherKit, CloudKit, real-model and device acceptance gates in [launch issue #142](https://github.com/TannerBarcelos/RoamReady/issues/142). Confirm storefront prices and the final policy/support URLs in App Store Connect.

## English (US) copy

| Field | Copy |
| --- | --- |
| Name | RoamReady |
| Subtitle | Camping trips, ready offline |
| Promotional text | Plan camping trips, run setup and teardown checklists, build menus and a grocery list, and keep bookings and manuals with you—even beyond reception. |
| Keywords | rv,camper,campground,checklist,trailer,motorhome,tent,booking,meal,grocery,weather,campsite,glamping (exactly 100 characters; leaves out words already in the name and subtitle) |
| Price | Free download. In-app purchases: RoamReady Pro Monthly $4.99, Yearly $34.99 (both with a 1-week free trial), Lifetime $99.99. See [Pricing](monetization.md). |
| Support URL | https://github.com/TannerBarcelos/RoamReady/issues |
| Privacy policy URL | https://github.com/TannerBarcelos/RoamReady/blob/main/docs/privacy-policy.md — verify it is public after merge, before submission. |

### Description

As submitted for 1.0 (Nov 16, 2026):

A little preparation. A lot more camping.

RoamReady brings your rig, camping trips, checklists, meals, paperwork, and memories together on iPhone and iPad. Plan at home and keep the essentials with you when reception disappears. No account required.

MAKE YOUR RIG FEEL LIKE YOURS
Keep your setup details, photo or emoji, and optional registration information handy. Replace your rig without losing the one recorded on past trips.

ARRIVE WITH A PLAN
Record a booking, campground, dates, site details, and confirmation paperwork. Add check-in times, a booking link, and notes about the site. RoamReady records your reservation; it does not make bookings or show availability.

CHECKLISTS THAT FIT YOUR FLOW
Start with setup and teardown lists tailored to your rig and equipment. Add, edit, reorder, complete, or skip steps. Each trip gets its own progress, and you choose when to update your reusable defaults.

MEALS AND GROCERIES
Plan each day's meals, list every dish's ingredients, and get a grocery list grouped by store section. Tap what you already have, and share the rest.

KEEP PAPERWORK AND MEMORIES CLOSE
Save manuals, insurance, registration, and trip confirmations as PDFs or images for offline access. Add campsite photos, captions, notes, and return-or-avoid ratings so your next visit starts with what you learned last time.

EXPLORE WHEN CONNECTED
Find campgrounds and RV parks through Apple Maps, save places to your lists, open their websites, or get directions. Check local weather and trip forecasts, with the last forecast saved for offline use.

ASK FOR CAMPING HELP
With RoamReady Pro on devices that support Apple Intelligence, ask camping and checklist questions and get answers from your own manuals and reservation paperwork, with the pages it used. Everything runs on your device; your documents never leave it. Check generated advice against your rig's manuals; it is not a substitute for qualified assistance.

BUILT FOR YOUR DEVICES
Optimized for iPhone Duo: on the open display, Home sits beside your trip and Camp Finder shows results beside a larger map. Optional private iCloud sync keeps your library across your Apple devices. Choose System, Light, or Dark appearance.

ROAMREADY PRO
RoamReady is free to download. Try everything free for a week, then choose monthly or yearly, or buy Lifetime once. Without Pro, everything you've saved stays readable; adding, editing, and the Assistant need Pro. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period, and you can manage or cancel them in your Apple Account settings.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

## Assets and account steps still needed

- **Optimized for iPhone Duo:** Apple's [preparation guide](https://developer.apple.com/iphone-duo/prepare/) ties this product-page badge to submitting Duo screenshots in App Store Connect; there is no app-side badge switch. CI already requires the iOS 27.1 SDK or newer. After #142 B14 acceptance on the shipping build, capture outer- and inner-display screenshots following Apple's [specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), upload and preview them in App Store Connect, and verify the badge after release. Duo screenshots become required in April 2027 for apps built with the iOS 27.1 SDK or newer. Keep the launch task unchecked until these steps are complete.
- Privacy label and notices: the Assistant's document indexing is on-device only (no data collected). Settings has no acknowledgements screen, so the sqlite-vec MIT/Apache-2.0 notice lives in the README, the provenance note, and the privacy policy; decide whether the owner wants an in-app screen before submission.

- Choose the final bundle ID and development team, provision the dedicated CloudKit container and WeatherKit, deploy the production schema, and validate the signed archive and checked-in icon.
- Capture actual Release-build screenshots on the required iPhone, iPad and Mac sizes. Useful screens: Home with a current trip, booking/site details, a personalized checklist, memories, and Camp Finder. Use demonstration data and photos you can publish. Do not present simulator AI test replies as real generated responses.
- Complete the App Store age-rating and export-compliance questionnaires using the shipped build. Confirm privacy declarations against the [privacy policy](privacy-policy.md), manifest and actual Apple capabilities; no answers have been submitted here.
- Create the three in-app purchases (IDs in [Pricing](monetization.md)), each with a review screenshot of the paywall, and attach them to the first version before submitting.
- Complete the Paid Apps Agreement, tax/banking information, pricing schedule, TestFlight and review steps in #142. Those require the owner's authorized Apple account.
