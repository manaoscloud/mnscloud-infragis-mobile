# Security

## Local Secrets

User tokens and offline unlock material must use platform secure storage. Do not store tokens in
plain SQLite rows. The tenant database is encrypted (SQLite3MultipleCiphers) with a random key per
tenant kept in secure storage (`lib/src/data/session_vault.dart`).

## Session

The app signs in with the platform account through `/infragis/auth/signin` and keeps its own field
session, independent of the App and of the POS (`UserToken` type I). The access token lasts 15
minutes and lives only in memory; the refresh token rotates on every use (an older one ends the
session). Native platforms keep the refresh token in secure storage; the web never sees it (HttpOnly
cookie scoped to `/api/v1/infragis/auth`). A 401 refreshes once and repeats the request; a refused
refresh asks for a new sign-in and keeps the encrypted data. Sessions saved by older versions (the
platform token) keep working until they expire.

## Offline Unlock

After the sign-in the app asks for a local PIN (4 to 8 digits) and, where the device has them
(Android, iOS, macOS, Windows), offers biometrics (`lib/src/security/app_lock.dart`). The PIN is kept
only as a PBKDF2-HMAC-SHA256 hash with a random salt in secure storage. With a PIN the encrypted copy
opens only after the unlock: when the app starts and after 5 minutes in the background. Five wrong
PINs in a row sign out (the copy stays encrypted on the device; the tokens and the PIN go). It is a
local data unlock only and never API authentication; sign-out, an expired session and a remote wipe
also remove the PIN.

## Revocation

When connectivity returns, the mobile app must refresh authorization and revocation state. If the
API removes tenant access (403/402), the app erases that tenant's local data, photos, database
file and key, and stops replaying pending writes. An expired session (401) only removes the token.

## Storage

Attachments must be uploaded through API-authorized flows. The mobile app must not construct
permanent public object URLs.
