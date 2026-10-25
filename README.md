# MNSCloud InfraGIS Mobile

MNSCloud InfraGIS Mobile is the public Flutter field client for the MNSCloud InfraGIS module.

The app signs in with the MNSCloud API account, keeps an encrypted offline copy of the tenant
(catalogs and assets), collects point assets with GPS and photos while offline, and synchronizes
through the InfraGIS sync contract (`docs/offline-sync.md`).

The application does not own business rules, tenant scope, billing, storage authorization,
synchronization acceptance, or conflict resolution. Those decisions belong to the MNSCloud API and
database.

## Scope

Implemented scope:

- MNSCloud API login and tenant environment selection (token in platform secure storage)
- encrypted SQLite copy per tenant (SQLite3MultipleCiphers, key in secure storage)
- bootstrap download of catalogs and assets, then incremental changes with tombstones
- map (MapLibre with the platform base map) and offline asset list
- point asset create/update/delete queue with GPS capture and asset type properties
- photos with GPS and capture time, uploaded once the asset exists on the server
- conflict and refusal presentation based on API decisions (keep mine / take the server)
- remote wipe when the API removes the tenant access
- work orders assigned to the technician: start, hold, finish or cancel with a note, notes,
  materials from Stock and their issue, checklist items, asset photos; queued offline with client
  operation UUIDs

Roadmap scope:

- offline unlock with local PIN or device biometrics
- offline base map packages (PMTiles download)
- network (ports, splices) in the field
- line and polygon drawing on the device

Out of scope:

- separate mobile backend
- permanent credentials in the app
- API authorization bypasses
- local-only billing or entitlement decisions
- public bucket/object URLs as an authorization boundary
- single-industry data modeling

## Target Platforms

Planned Flutter targets:

- Android
- iOS
- Windows
- Linux
- macOS

## Authentication

InfraGIS Mobile reuses the MNSCloud API authentication contract.

Online login flow:

1. User configures or selects an authorized MNSCloud API base URL.
2. App calls `POST /api/v1/auth/signin`.
3. App calls `/api/v1/user/access` to list authorized tenant environments.
4. User selects one tenant environment.
5. App sends `Authorization: Bearer <token>` and `X-Environment-UUID: <environment_uuid>`.

Offline unlock is local access to previously authorized encrypted data. It is not a new login.

## Offline Data Roadmap

SQLite is the canonical local database for offline field operations.

Local data is expected to include:

- projects
- layers
- assets
- asset geometry
- attachments metadata
- work orders
- checklists
- sync cursors
- pending operations
- conflict records

## API Boundary

The app consumes only documented MNSCloud API contracts. Sensitive behavior stays API-side:

- session validation
- tenant access
- entitlement and billing checks
- storage object path ownership
- signed URL generation
- sync operation acceptance
- conflict resolution
- revocation

## Repository Layout

```text
mnscloud-infragis-mobile/
  README.md
  CONTRIBUTING.md
  SECURITY.md
  SKILL.md
  AGENTS.md
  pubspec.yaml
  analysis_options.yaml
  docs/
    architecture.md
    api-contract.md
    offline-sync.md
    security.md
    roadmap.md
  lib/
    main.dart
  test/
```

Native platform folders should be generated only when packaging for the target platforms:

```bash
flutter create --platforms android,ios,windows,linux,macos .
```

Run that command only in a clean working tree and review generated files before committing.

## Validation

```bash
flutter pub get
flutter analyze
flutter test
```
