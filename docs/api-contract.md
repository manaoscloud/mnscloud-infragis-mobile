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

## Planned InfraGIS Sync

```text
GET  /api/v1/infragis/sync/bootstrap
GET  /api/v1/infragis/sync/changes
POST /api/v1/infragis/sync/push
POST /api/v1/infragis/sync/ack
GET  /api/v1/infragis/offline/packages
POST /api/v1/infragis/offline/packages/:uuid/download-token
```

These endpoints are planned and must be implemented in MNSCloud API before the mobile app depends on
them.
