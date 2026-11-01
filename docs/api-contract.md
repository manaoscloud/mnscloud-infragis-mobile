# API Contract

The mobile app consumes the MNSCloud API.

## Login

```text
POST /api/v1/auth/signin
GET  /api/v1/user/access
```

Tenant requests must include:

```text
Authorization: Bearer <token>
X-Environment-UUID: <environment_uuid>
```

## InfraGIS (current)

```text
GET  /api/v1/infragis/accounts?status=1         (tenant.infragis.accounts.read or projects.read)
GET  /api/v1/infragis/accounts/:uuid             (tenant.infragis.accounts.read or projects.read)
GET  /api/v1/infragis/map/config                 (tenant.infragis.assets.read)
GET  /api/v1/infragis/sync/bootstrap?accountUUID= (tenant.infragis.assets.read)
GET  /api/v1/infragis/sync/changes?cursor=&accountUUID= (tenant.infragis.assets.read)
POST /api/v1/infragis/sync/push                  (tenant.infragis.assets.write)
POST /api/v1/infragis/assets/:uuid/attachments   (tenant.infragis.assets.write, multipart)
```

Responses use the canonical envelope `{ status, message, data, duration }`.

- Accounts (resale): the list and the item answer only the accounts in the operator scope
  (`IgcUUID`, `IgcName`, `IgcIsLegacy`, `CustomerName`, `IgcStatus`); an account outside it is 404.
  `accountUUID` limits bootstrap and changes to one account; without it they carry every account
  the operator may use.
- Bootstrap pages carry `items`, `cursor`, `done`; the first page also carries `catalog` (projects,
  layers, categories, asset-types, statuses). The last cursor continues with `changes`.
- Changes return assets changed after the cursor; deleted ones as `{ IgaUUID, deleted: true }`.
- Push takes up to 100 operations `{ uuid, kind: asset.create|asset.update|asset.delete,
  assetUUID, baseSyncAt?, data? }` and answers one result per operation: `ACCEPTED`, `DUPLICATE`
  (same uuid and payload already applied), `CONFLICT` (`reason` changed/deleted, with the server
  `item`), `REJECTED` (`error`) or `RETRY`.
- Attachments take `file`, `attachmentUUID` (idempotent retry), `kind`, `caption`,
  `latitude`/`longitude` and `capturedAt`.

## Work orders (Work orders module)

```text
GET  /api/v1/workorders/orders?mine=1&openOnly=1&limit=200   (tenant.workorders.orders.read)
GET  /api/v1/workorders/orders/:uuid/materials               (tenant.workorders.orders.read)
GET  /api/v1/workorders/orders/:uuid/checklist               (tenant.workorders.orders.read)
PUT  /api/v1/workorders/checklist/:item                       (tenant.workorders.orders.write)
POST /api/v1/workorders/orders/:uuid/status                  (tenant.workorders.orders.write)
POST /api/v1/workorders/orders/:uuid/notes                   (tenant.workorders.orders.write)
POST /api/v1/workorders/orders/:uuid/materials               (tenant.workorders.orders.write)
POST /api/v1/workorders/orders/:uuid/materials/issue         (tenant.workorders.orders.write)
GET  /api/v1/sale/products?limit=1000                        (Stock picker)
GET  /api/v1/stock/locations?limit=500                       (Stock picker)
```

- `status` takes `status`, `note` (required for DONE and CANCELLED) and `operationUUID`; `notes`
  takes `note` and `operationUUID`. A repeated `operationUUID` on the same order is answered with
  the current state; on another order it is refused.
- `materials` takes `materialUUID`, `productUUID`, `locationUUID`, `quantity`; a repeated
  `materialUUID` returns the same material.
- `materials/issue` moves the planned materials out of Stock; issuing twice has nothing left to move.
- `checklist/:item` takes `done` (and optional `note`) and sets the state, so a retry is harmless;
  DONE is refused while a required item is open.

## Not yet available

```text
GET  /api/v1/infragis/offline/packages
POST /api/v1/infragis/offline/packages/:uuid/download-token
```

Offline base map packages need the platform PMTiles host; until then the map needs a connection
for the base layer (the assets are always local).
