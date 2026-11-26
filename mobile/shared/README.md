# Shared app files

Both native apps read the files in this folder. The web app stays the source of
truth: generators copy its tokens and strings here, and a test fails when a copy
is out of date. Section 14 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md)
has the full table of sources, generators and checks. Where that section
names a single `mobile/shared/tokens.json`, the generated tokens live in the
`tokens/` folder instead.

| Folder | What it holds | Made from | Made by |
|---|---|---|---|
| [tokens/](tokens/README.md) | colour and type tokens | the `.stride-screen` tokens in `assets/css/app.css` | `mix mobile.tokens` (generated) |
| [strings/](strings/README.md) | app strings in seven locales | `priv/gettext/*/LC_MESSAGES/mobile.po` | `mix mobile.strings` (generated) |
| [fixtures/](fixtures/README.md) | example API responses | `priv/openapi/stride-api.json` | written by hand, checked against the contract |
| [openapi.json](openapi.json) | the API contract, which the Android app generates its client from | `priv/openapi/stride-api.json` | `mix mobile.api` (checked, then copied byte for byte) |

`mix mobile.tokens`, `mix mobile.strings` and `mix mobile.api` exist, and
`tokens/tokens.json`, the seven `strings/<locale>.json` files and
`openapi.json` are generated. `fixtures/` holds one
hand-written example response per `/api/me` and `/oauth` operation whose
success response has a JSON body, and
`test/kanban_web/controllers/api/mobile_fixtures_test.exs` checks each against
the contract.

`mix mobile.strings` also writes a file outside this folder, the iOS app's string
catalog `mobile/ios/Stride/Resources/Localizable.xcstrings`. It is built by
`Kanban.Mobile.StringCatalog`, and `test/kanban/mobile/string_catalog_test.exs`
fails when it is stale.

`mix mobile.api` checks `priv/openapi/stride-api.json` before it copies it:
the contract must parse, every operation needs a unique `operationId`, and
every `/api/me` operation must require `deviceAuth` and give a response schema
for each 2xx response that has a body. It writes nothing when a rule fails.
`test/kanban/mobile/api_contract_test.exs` fails when `openapi.json` is stale;
refresh it with `MIX_ENV=test mix mobile.api`. Each app's own build generates
its client, so no client generator runs in the Elixir build. The Android build
will read `openapi.json` with the Gradle OpenAPI plugin; its config is not
committed yet.

The iOS build reads a second document that the same task writes,
`mobile/ios/StrideKit/Sources/StrideKit/openapi.json`. It is derived from the
contract by `Kanban.Mobile.SwiftContract`, which loosens only what the Swift
OpenAPI Generator would drop or refuse: for example, it opens the enums the app
reads, so a value the API adds later still decodes. Its module documentation
lists every change. `test/kanban/mobile/swift_contract_test.exs` fails when that
document is stale.

Never edit a generated file by hand: change its source and run the
generator.
