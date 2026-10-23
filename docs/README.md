# RoamReady documentation

RoamReady keeps camping trips, rig details, checklists, documents, and memories together, with core workflows available offline. This documentation describes the current development build and separates implemented behavior from future work.

## Use the app

| Guide | What it covers |
| --- | --- |
| [User guide](user-guide.md) | First launch, trips, checklists, documents, memories, discovery, and managing your library. |
| [Feature reference](features.md) | Implemented behavior, offline support, device requirements, and feature limits. |

## Understand the design and implementation

| Guide | What it covers |
| --- | --- |
| [Design](design.md) | System-first interface, navigation, forms, status, and accessibility expectations. |
| [Architecture](architecture.md) | Package boundaries, source layout, data flow, integrations, and media handling. |
| [Offline storage and sync](offline-storage.md) | SwiftData models, relationships, conflicts, CloudKit setup, and schema rules. |
| [Identity, connectivity, and AI](account-and-offline-contract.md) | Account-free ownership, iCloud identity, network boundaries, and on-device AI eligibility. |
| [Document vault](document-vault.md) | Imports, encryption, integrity checks, availability, APIs, and export format. |
| [Erasing data](erase-data.md) | Trip/document deletion and the full-library erase process. |

## Build, validate, and release

| Guide | What it covers |
| --- | --- |
| [Build and validation](validation.md) | Local setup, dependencies, checks, CI, Apple capabilities, and device acceptance. |
| [Production integrations and release plan](integration-plan.md) | Current implementation, provisioning work, release gates, and deferred features. |

## Data and product planning

| Guide | What it covers |
| --- | --- |
| [Data sources and coverage](campground-data.md) | Owner-entered rigs, Apple Maps coverage, saved-place storage, and attribution. |
| [Camp Finder data source](campground-sourcing.md) | Map/search behavior, place details, identifiers, provider limits, and acceptance. |
| [Monetization proposal](monetization.md) | Draft subscription and remote-AI proposals; these are not implemented features. |

## Maintaining these docs

Keep the [repository README](../README.md) focused on the app, its purpose, basic setup, and links here. Put detailed behavior in the feature reference, task instructions in the user guide, implementation details in the architecture or specialist guides, and unfinished work in the release plan. Update the relevant guide and this index when behavior or document locations change.

The source code and checked-in configuration define current behavior. Research dates and proposed decisions do not establish production readiness; use the [validation guide](validation.md) and workflow results to assess a particular build.
