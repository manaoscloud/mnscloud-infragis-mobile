# Offline Sync

The offline copy of each tenant is one SQLite database encrypted with SQLite3MultipleCiphers
(`package:sqlite3` build option `source: sqlite3mc`). Its key is random per tenant and lives in the
platform secure storage with the session token; neither is written to SQLite or plain files.

Tables (`lib/src/data/local_store.dart`):

- `meta`: sync cursor, last sync, catalog refresh time
- `catalog`: projects, layers, categories, asset types and statuses
- `asset`: the asset copy with its server `syncAt`
- `outbox`: queued writes in order (`pending`, `conflict`, `rejected`) with backoff
- `photo_outbox`: photos waiting for upload (file path, GPS, capture time)

## Flow (`lib/src/sync/sync_engine.dart`)

1. Online login through the MNSCloud API and tenant selection (`/user/access`).
2. Push: queued writes go in order (at most 100 per call). Each operation UUID is the idempotency
   key: a retry is answered `DUPLICATE` with the stored result. Updates and deletes carry
   `baseSyncAt`, the server version the edit started from.
3. Photos: uploaded only when their asset has no queued create left; the client attachment UUID
   makes the retry idempotent.
4. Pull: without a cursor, a full bootstrap (catalogs and assets; the previous server copies are
   replaced once the server answers); with a cursor, the changes since it, deleted assets as
   tombstones. Catalogs refresh at most once an hour.
5. Assets with queued writes keep the local version until the server accepts or the user resolves.

The app syncs when it opens, after each local write and every two minutes.

## Conflict Rule

The API decides. `CONFLICT` keeps the operation with the server item: the user keeps the local
change (it goes again on top of the server version) or takes the server version. `REJECTED` shows
the API reason; the user discards it (a refused offline create removes the asset and its photos).
`RETRY` and network failures back off up to 15 minutes.

## Revocation

- 401: the session expired; the token goes, the encrypted copy stays for the next sign-in.
- 403/402: the tenant access or the module was removed; the local copy, its photos, its database
  file and its key are erased (remote wipe).
