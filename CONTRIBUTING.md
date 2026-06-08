# Contributing

Thank you for helping improve MNSCloud InfraGIS Mobile.

## Public Client Boundary

This repository is a public API client. Do not add:

- permanent secrets
- customer data
- production IPs/domains
- provider credentials
- database credentials
- JWT signing secrets
- private topology
- API-side authorization or billing decisions

Use placeholders in examples, such as `<api_base>`, `<environment_uuid>`, and `<token>`.

## Workflow

1. Open an issue or discussion for large changes.
2. Create a feature branch.
3. Keep business rules in the API contract.
4. Add or update documentation with behavior changes.
5. Open a pull request.

Direct pushes to `main` are not part of the contribution workflow.

## Validation

Until the Flutter scaffold is generated, run:

```bash
git diff --check
```

After Flutter is added, expected validation will include:

```bash
flutter pub get
flutter analyze
flutter test
```
