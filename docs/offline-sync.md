# Offline Sync

SQLite is the canonical local offline database.

Local data should be grouped into:

- projects
- layers
- assets
- asset geometry
- attachment metadata
- work orders
- checklists
- sync cursors
- pending operations
- conflict records

## Flow

1. Online login through the MNSCloud API.
2. Tenant selection through `/api/v1/user/access`.
3. Authorized bootstrap download.
4. Offline field operation.
5. Pending operation queue writes to SQLite.
6. Retry and push when connectivity returns.
7. API validates permissions, entitlement, version, and conflict state.
8. Mobile applies API response and advances sync cursor.

## Conflict Rule

The mobile app may present conflicts. The API decides whether an operation is accepted, rejected, or
requires user/admin resolution.
