# API fixtures

Example API responses, one JSON file per response, used by app previews, tests
and screenshots. They are written by hand, not generated, but an ExUnit test
checks each one against its schema in the API contract,
`priv/openapi/stride-api.json`, so they cannot drift from the API.

When the contract changes, update the fixtures it affects in the same task.
Use made-up data only: never a real token, email address or customer record.
See section 7.11 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).
