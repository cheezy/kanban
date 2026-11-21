# App strings

Generated. `mix mobile.strings` reads the `mobile` gettext domain,
`priv/gettext/*/LC_MESSAGES/mobile.po`, and writes the strings for all seven
locales: de, en, es, fr, ja, pt and zh. It converts gettext's `%{name}`
placeholders to each platform's format. A test fails when a string is missing
in any locale or a copy is stale.

Never edit these files by hand. Add or change the string in gettext, run
`mix gettext.extract --merge`, translate it in every locale, then run
`mix mobile.strings` and commit the result in the same task. See sections 14
and 17 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).
