# Stride native apps

This folder holds the native iOS and iPadOS app and the Android app. The
Phoenix app stays at the repository root and is the source of truth for the
API, the design tokens and the strings.
[AGENTS.md](../AGENTS.md) still applies: its quality and security rules (tests
for new code, dependency audits) bind app work too, and its Phoenix, Elixir and
web UI rules bind any change outside `mobile/`. The rules below add what the
apps need.

The design is
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md);
section 14 has this folder's layout and section 17 has the translation,
accessibility and dark mode rules.

## Layout

- `ios/` is the iOS and iPadOS app. Its own rules are in [ios/CLAUDE.md](ios/CLAUDE.md).
- `android/` is the Android app. Its own rules are in [android/CLAUDE.md](android/CLAUDE.md).
- `shared/` holds the files both apps read: the generated tokens and strings, and example API responses. [shared/README.md](shared/README.md) says what is generated there and from what.

## Rules for both apps

- **Support both themes.** Every screen works in light and dark mode. Take every colour from the generated tokens, never a hard-coded value, so the apps match the web's `.stride-screen` palette. Text reaches 4.5:1 contrast and form-control borders 3:1 in both themes, as [docs/dark-mode-contract.md](../docs/dark-mode-contract.md) requires for the web.
- **Ship all seven locales.** Every visible string is in the `mobile` gettext domain and is translated into de, en, es, fr, ja, pt and zh in the same task, never left for later. Never hard-code a user-visible string in Swift or Kotlin. Status values arrive from the API as enums and are shown through the `mobile` strings, so the apps and the web never read differently.
- **Label everything for accessibility.** Every control has a VoiceOver or TalkBack label. A state shown by colour, such as a verdict or status pill, also says it in words. Nothing depends on a swipe alone.
- **Keep business logic out of views.** Views render state and send user intents. Decisions, API calls, caching and formatting live in view models and the shared modules, where tests reach them through the shared fixtures.
- **Regenerate after changing a source.** After changing the API contract (`priv/openapi/stride-api.json`), the tokens (`assets/css/app.css`) or the strings (`priv/gettext/*/LC_MESSAGES/mobile.po`), run the matching generator (`mix mobile.api`, `mix mobile.tokens` or `mix mobile.strings`) and commit the copies in the same task. Never edit a generated copy by hand: a test fails when a copy is stale. `mix mobile.tokens`, `mix mobile.strings`, `mix mobile.api` and their staleness tests exist. `mix mobile.api` checks the contract and copies it to `shared/openapi.json`. Each app's own build will generate its API client from that copy once the app projects exist (Phase 1b and 1c); no generator config is committed yet. The Elixir CI workflow skips a pull request confined to `mobile/`, so run the staleness tests locally before committing one.
- **One task can span the API and both apps.** When an API change affects an app, change the contract, the server and both apps together rather than leaving one app behind.
- **Never commit signing material or machine paths.** Keystores, `.p8` and `.p12` keys, provisioning profiles and `local.properties` are ignored by `.gitignore`; keep it that way.

## CI

Each app has its own workflow, separate from the Elixir one:
[ios.yml](../.github/workflows/ios.yml) runs on macOS and
[android.yml](../.github/workflows/android.yml) on Linux. Each runs when its
app, `shared/` or the API contract (`priv/openapi/`) changes, so a contract
change runs both. Each workflow pins its toolchain at the top of the file.

Each one is skipped until its project exists: `ios.yml` looks for
`ios/project.yml` and `android.yml` for `android/settings.gradle.kts`, and
reports its build jobs as skipped while the file is missing. The workflows use
no secrets, so pull requests from forks run them too. The names each workflow
relies on are in [ios/CLAUDE.md](ios/CLAUDE.md) and
[android/CLAUDE.md](android/CLAUDE.md); change a workflow when you change one
of those names.
