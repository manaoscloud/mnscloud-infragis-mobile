# MNSCloud InfraGIS Mobile

MNSCloud InfraGIS Mobile is the public Flutter field client for the MNSCloud InfraGIS module.

The current implementation is an online API client shell with API base configuration, MNSCloud API
login, tenant environment selection, InfraGIS dashboard metrics, and project listing. Offline-first
sync remains a roadmap item owned by the API contract.

The application does not own business rules, tenant scope, billing, storage authorization,
synchronization acceptance, or conflict resolution. Those decisions belong to the MNSCloud API and
database.

## Scope

Implemented scope:

- MNSCloud API login
- tenant environment selection
- InfraGIS dashboard read
- InfraGIS project list read

Roadmap scope:

- offline unlock with local PIN or device biometrics
- project, layer, and asset download
- SQLite local cache
- offline asset lookup
- offline create/update queue
- offline photos and attachments
- GPS capture
- work orders and checklists
- incremental synchronization
- conflict presentation based on API decisions

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
