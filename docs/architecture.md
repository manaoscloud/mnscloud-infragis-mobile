# Architecture

InfraGIS Mobile is a Flutter API client for field operations.

```text
Flutter UI
  -> application use cases
  -> domain interfaces
  -> infrastructure adapters
       -> MNSCloud API
       -> SQLite
       -> secure local storage
       -> device GPS/camera/files
```

The MNSCloud API and database own:

- authentication
- tenant access
- billing and entitlement
- storage authorization
- sync acceptance
- conflict decisions
- revocation

The mobile app owns:

- local presentation
- local encrypted cache
- offline pending operation queue
- user-friendly conflict display
- retry after reconnection

## Public Client Boundary

This repository can be public because it does not contain backend authority or permanent secrets.
