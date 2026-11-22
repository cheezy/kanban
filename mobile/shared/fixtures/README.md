# API fixtures

Example API responses, one JSON file per response, used by app previews, tests
and screenshots. They are written by hand, not generated, but an ExUnit test
checks each one against its schema in the API contract,
`priv/openapi/stride-api.json`, so they cannot drift from the API.

## The rules the test enforces

`test/kanban_web/controllers/api/mobile_fixtures_test.exs` fails when any of
these is broken:

- **One file per operation.** Every `/api/me` and `/oauth` operation whose
  success response has a JSON body needs a fixture named after its
  `operationId`, for example `getMe.json` or `oauthToken.json`. The test reads
  the list from the contract, so a new operation fails it until its fixture
  exists. A `204` response has no body and needs no fixture.
- **The whole body.** A fixture holds exactly what the API sends, including
  the `{"data": ...}` envelope the `/api/me` routes use.
- **Nothing the contract does not promise.** A fixture must validate against
  its response schema, and it may not carry a key the schema does not declare.
  When the two disagree, fix the fixture, never the schema.
- **Made-up data only.** Never a real token, email address, hostname or
  customer record. Links use hosts under `.example`, for example
  `https://stride.example/`, and token values read
  `EXAMPLE-...-for-previews-only`.

Keep lists populated, so the test checks their items rather than passing on an
empty array, and show `null` where the app must handle it. The test also walks
every response schema whole, so a keyword the validator cannot check fails the
test even in a branch or optional field that no fixture reaches.

## Checking a change

When the contract changes, update the fixtures it affects in the same task,
then run:

```bash
MIX_ENV=test mix test test/kanban_web/controllers/api/mobile_fixtures_test.exs
```

Run it yourself when a change touches only `mobile/`: a pull request that
changes nothing else skips the Elixir workflow, so CI does not run it there.

See section 7.11 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).
