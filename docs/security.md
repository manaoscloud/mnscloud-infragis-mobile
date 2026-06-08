# Security

## Local Secrets

User tokens and offline unlock material must use platform secure storage. Do not store tokens in
plain SQLite rows.

## Offline Unlock

Offline unlock can use biometrics or a local PIN after a successful online login. It is only a local
data unlock mechanism and must not be treated as API authentication.

## Revocation

When connectivity returns, the mobile app must refresh authorization and revocation state. If the
API removes tenant access, the app must block that tenant context locally and stop replaying pending
writes.

## Storage

Attachments must be uploaded through API-authorized flows. The mobile app must not construct
permanent public object URLs.
