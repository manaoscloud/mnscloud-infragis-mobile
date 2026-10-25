# Security

## Local Secrets

User tokens and offline unlock material must use platform secure storage. Do not store tokens in
plain SQLite rows. The tenant database is encrypted (SQLite3MultipleCiphers) with a random key per
tenant kept in secure storage (`lib/src/data/session_vault.dart`).

## Offline Unlock

Offline unlock can use biometrics or a local PIN after a successful online login. It is only a local
data unlock mechanism and must not be treated as API authentication.

## Revocation

When connectivity returns, the mobile app must refresh authorization and revocation state. If the
API removes tenant access (403/402), the app erases that tenant's local data, photos, database
file and key, and stops replaying pending writes. An expired session (401) only removes the token.

## Storage

Attachments must be uploaded through API-authorized flows. The mobile app must not construct
permanent public object URLs.
