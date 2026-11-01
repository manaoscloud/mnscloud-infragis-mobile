# Offline Sync

The offline copy of each tenant and InfraGIS account is one SQLite database encrypted with
SQLite3MultipleCiphers (`package:sqlite3` build option `source: sqlite3mc`), file
`infragis-<tenant>-<account>.db` (`infragis-<tenant>.db` for the tenant-wide copy below). Its key is
random per copy and lives in the platform secure storage with the session token; neither is written
to SQLite or plain files.

Tables (`lib/src/data/local_store.dart`):

- `meta`: sync cursor, last sync, catalog refresh time
- `catalog`: projects, layers, categories, asset types and statuses
- `asset`: the asset copy with its server `syncAt`
- `outbox`: queued writes in order (`pending`, `conflict`, `rejected`) with backoff
- `photo_outbox`: photos waiting for upload (GPS, capture time); their bytes live in `photo_blob`
  inside the same encrypted database (no loose files, the same on the web)

## Flow (`lib/src/sync/sync_engine.dart`)

1. Online login through the MNSCloud API, tenant selection (`/user/access`) and account selection
   (`GET /infragis/accounts`: one account opens directly, several ask). The sync calls carry
   `accountUUID`. Without accounts to list (no permission, an older server) the copy is tenant-wide
   and syncs every account the operator may use, as before. A tenant-wide copy of an older version
   with work still queued opens first; it is removed once the operator switches to an account with
   nothing waiting.
   Switching accounts (top bar) syncs first and needs an empty queue; each account keeps its copy.
2. Push: queued writes go in order (at most 100 per call). Each operation UUID is the idempotency
   key: a retry is answered `DUPLICATE` with the stored result. Updates and deletes carry
   `baseSyncAt`, the server version the edit started from.
3. Photos: uploaded only when their asset has no queued create left; the client attachment UUID
   makes the retry idempotent.
4. Work orders (only with the Work orders module): queued actions go in order; status and note
   carry `operationUUID`, a material carries its own `materialUUID` and a checklist check sets the
   item state, so a retry is a no-op. A
   refusal stays on the order until the user discards it. Then the assigned open orders, their
   materials and checklists are replaced (queued actions re-applied on top) and the Stock products and locations
   refresh at most hourly. A 402/403 on these routes only hides the tab; it never wipes the copy.
5. Pull: without a cursor, a full bootstrap (catalogs and assets; the previous server copies are
   replaced once the server answers); with a cursor, the changes since it, deleted assets as
   tombstones. Catalogs refresh at most once an hour.
6. Assets with queued writes keep the local version until the server accepts or the user resolves.

The app syncs when it opens, after each local write and every two minutes.

## Conflict Rule

The API decides. `CONFLICT` keeps the operation with the server item: the user keeps the local
change (it goes again on top of the server version) or takes the server version. `REJECTED` shows
the API reason; the user discards it (a refused offline create removes the asset and its photos).
`RETRY` and network failures back off up to 15 minutes.

## Revocation

- 401: the session expired; the token goes, the encrypted copy stays for the next sign-in.
- 403/402: the tenant access or the module was removed; the local copies of the tenant (every
  account), their photos, database files and keys are erased (remote wipe).
- Lost account: before each sync the app reads its account (`GET /infragis/accounts/:uuid`). A 404
  (assignment removed, account deleted) or an inactive account erases that account's copy and key,
  and the operator chooses again. Only a suspended contract (service unavailable, account active)
  keeps the copy: existing work stays editable, as on the App. A 403 or no answer on this read
  changes nothing.
