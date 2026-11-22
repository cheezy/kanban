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

`mix mobile.tokens` and `mix mobile.strings` exist, and `tokens/tokens.json`
and the seven `strings/<locale>.json` files are generated. `fixtures/` holds one
hand-written example response per `/api/me` and `/oauth` operation whose
success response has a JSON body, and
`test/kanban_web/controllers/api/mobile_fixtures_test.exs` checks each against
the contract. The API generator and its check arrive with a later task of the
goal. Never edit a generated file by hand: change its source and run the
generator.
