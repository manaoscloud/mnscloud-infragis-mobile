# mnscloud-infragis-mobile Skill

Use this repository for the MNSCloud InfraGIS Flutter mobile field client.

## Rules

- This is a public API client.
- Do not add permanent secrets, customer data, production topology, provider credentials, or API-side
  authority.
- Do not implement a separate mobile backend.
- Reuse MNSCloud API login through `POST /api/v1/auth/signin`.
- Resolve tenant environments through `/api/v1/user/access`.
- Send `Authorization: Bearer <token>` and `X-Environment-UUID` for tenant requests.
- Treat offline unlock as local device access only, not as a new login.
- Use SQLite as the canonical offline database.
- Keep business rules, billing, authorization, storage path ownership, signed URL generation, sync
  acceptance, and conflict decisions in DB/API.
- Follow `/opt/mnscloud/docs/infragis.md` for the canonical product contract.

## Validation

Before Flutter scaffold exists:

```bash
git diff --check
```

After Flutter scaffold exists:

```bash
flutter pub get
flutter analyze
flutter test
```
