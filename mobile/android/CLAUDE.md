# Stride for Android

The rules in [../CLAUDE.md](../CLAUDE.md) apply here too. This file adds the
Android ones. Section 13 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md)
has the platform choices behind them.

- **Support both themes.** Use the generated Compose colour scheme and typography, with no dynamic colour, and check every screen in light and dark before you finish.
- **Ship all seven locales.** Show every string through the `strings.xml` files generated from the `mobile` gettext domain, in de, en, es, fr, ja, pt and zh. Never put a user-visible literal in Kotlin. Check layouts at 200% font scale in German, where labels run longest.
- **Label everything for accessibility.** Give every control a TalkBack content description, support font scaling to 200%, keep touch targets at least 48 dp, and run the Accessibility Test Framework checks in the UI tests.
- **Keep business logic out of views.** Composables render `StateFlow` state from view models and send events back. Networking, auth, data and push belong in the `core` modules, and view models are tested against `mobile/shared/fixtures/`.
- **Regenerate after changing a source.** After the API contract changes, regenerate the Kotlin client with `mix mobile.api`; after the tokens or strings change, run `mix mobile.tokens` or `mix mobile.strings`. Never edit generated files by hand.
- **Never commit build output or machine paths.** `build/`, `.gradle/` and `local.properties` are ignored.
- **Never commit signing material.** Keystores (`.jks`, `.keystore`) stay out of the repository.
