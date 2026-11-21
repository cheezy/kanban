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

The generators and their checks arrive with the goal's later tasks; until a
folder's generator exists, it holds only its README. Never edit a generated
file by hand: change its source and run the generator.
