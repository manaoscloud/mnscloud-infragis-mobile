# AGENTS.md

Project capsule for AI agents working in `mnscloud-infragis-mobile`.

## Overview

- Repo: `mnscloud-infragis-mobile`
- Purpose: public Flutter offline-first field client for MNSCloud InfraGIS
- API boundary: consumes MNSCloud API only
- Backend: none in this repository
- Local database: SQLite

## Non-Negotiable Rules

- Do not commit secrets, customer data, production IPs/domains, provider credentials, JWT signing
  secrets, database credentials, private topology, or master keys.
- Do not move API-side authorization, tenant scope, billing, sync acceptance, conflict resolution,
  or storage ownership into the mobile app.
- Keep docs/examples placeholder-based.
- Use the MNSCloud API login flow; do not create a mobile-only auth backend.
- Offline unlock can use local PIN/biometrics only after successful online login and authorized data
  download.

## Canonical References

- Workspace contract: `/opt/mnscloud/docs/infragis.md`
- Public clients: `/opt/mnscloud/docs/public-api-clients.md`
- Storage contract: `/opt/mnscloud/docs/storage-file-contract.md`

## Expected Future Validation

```bash
flutter pub get
flutter analyze
flutter test
```
