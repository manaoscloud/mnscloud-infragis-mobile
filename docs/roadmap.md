# Roadmap

Done (F5, `infragis-field-offline`):

1. Secure token storage.
2. Encrypted SQLite schema and migrations.
3. Bootstrap and incremental sync.
4. Offline project/layer/asset cache and map.
5. Pending operation queue with backoff.
6. GPS and photo capture.
7. Sync push, conflict and refusal presentation, remote wipe.
8. Native Android and iOS folders (location and camera permissions).

Done (`infragis-field-work-orders`):

1. Work orders tab (Work orders module only): my open orders, status moves, notes, materials
   and their issue, offline queue idempotent by operation UUID.
2. Work order checklists (`workorders-checklists-sla`): check items offline; finishing waits for the
   required ones.

Done (`infragis-offline-maps`, Flutter clients program phase 3b):

1. Own field session (`/infragis/auth/*`, UserToken type I) with a rotating refresh token: 15-minute
   access token, 14 days idle and 30 days at most, so field work stays offline for days.
2. Offline unlock with a local PIN and device biometrics (`docs/security.md`).
3. Offline base map areas downloaded from the platform base map into the encrypted database
   (`docs/offline-maps.md`); the style and the map configuration are kept for offline starts.

Next:

1. Work order checklist photos per item.
2. Network (ports, splices) and line/polygon drawing in the field.
3. Device provisioning by QR code from the App (no API address typed on native platforms).
4. Store release packaging (signing, store listings).
