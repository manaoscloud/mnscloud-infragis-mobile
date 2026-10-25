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
GET  /api/v1/infragis/map/config                 (tenant.infragis.assets.read)
GET  /api/v1/infragis/sync/bootstrap             (tenant.infragis.assets.read)
GET  /api/v1/infragis/sync/changes?cursor=       (tenant.infragis.assets.read)
POST /api/v1/infragis/sync/push                  (tenant.infragis.assets.write)
POST /api/v1/infragis/assets/:uuid/attachments   (tenant.infragis.assets.write, multipart)
```

Responses use the canonical envelope `{ status, message, data, duration }`.

- Bootstrap pages carry `items`, `cursor`, `done`; the first page also carries `catalog` (projects,
  layers, categories, asset-types, statuses). The last cursor continues with `changes`.
- Changes return assets changed after the cursor; deleted ones as `{ IgaUUID, deleted: true }`.
- Push takes up to 100 operations `{ uuid, kind: asset.create|asset.update|asset.delete,
  assetUUID, baseSyncAt?, data? }` and answers one result per operation: `ACCEPTED`, `DUPLICATE`
  (same uuid and payload already applied), `CONFLICT` (`reason` changed/deleted, with the server
  `item`), `REJECTED` (`error`) or `RETRY`.
- Attachments take `file`, `attachmentUUID` (idempotent retry), `kind`, `caption`,
  `latitude`/`longitude` and `capturedAt`.

## Not yet available

```text
GET  /api/v1/infragis/offline/packages
POST /api/v1/infragis/offline/packages/:uuid/download-token
```

Offline base map packages need the platform PMTiles host; until then the map needs a connection
for the base layer (the assets are always local).
