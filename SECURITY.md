# Security Policy

## Reporting a Vulnerability

Please report security concerns privately to the MNSCloud maintainers. Do not publish secrets,
customer data, exploit payloads, or private infrastructure details in public issues.

## Public Repository Rules

This repository must not contain:

- tokens
- passwords
- private keys
- cloud credentials
- Mapbox tokens
- API signing secrets
- provider credentials
- customer data
- production topology

The mobile app may store user session material only on the user's device using secure storage after
successful API authentication.

## Offline Security

Offline unlock is local access to previously authorized data. The MNSCloud API remains responsible
for session validity, tenant access, sync acceptance, conflict decisions, and revocation.
