# App strings

Generated. `mix mobile.strings` reads the `mobile` gettext domain,
`priv/gettext/mobile.pot` and `priv/gettext/<locale>/LC_MESSAGES/mobile.po`,
and writes one file per locale here: [de.json](de.json), [en.json](en.json),
[es.json](es.json), [fr.json](fr.json), [ja.json](ja.json),
[pt.json](pt.json) and [zh.json](zh.json). `Kanban.Mobile.Strings` in
`lib/kanban/mobile/strings.ex` lists every app string.

Never edit these files by hand. To add or change a string:

1. Add or change its `dpgettext_noop("mobile", key, text)` call in
   `Kanban.Mobile.Strings.msgids/0`.
2. Run `MIX_ENV=test mix gettext.extract --merge`.
3. Translate it in every locale's `mobile.po` and leave no `fuzzy` flag.
4. Run

   ```bash
   MIX_ENV=test mix mobile.strings
   ```

5. Commit the `.po` files and these copies in the same task.

`test/kanban/mobile/strings_test.exs` fails while a copy is stale, and when a
string is missing, empty, fuzzy or loses a placeholder in any locale. The
Elixir CI workflow skips a change confined to `mobile/`, so run that test
locally before committing one. See sections 14 and 17 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## What each file holds

- `strings`: `key => text` for each singular string.
- `plurals`: `key => {category => text}`, keyed by the CLDR plural category
  each platform's plural resources use. de, en, es, fr and pt have `one` and
  `other`; ja and zh have `other` only. The categories come from the locale's
  `Plural-Forms` header. gettext's pt rule treats 0 as plural while CLDR's
  treats it as `one`, so a pt string read for 0 can differ from the web's.
- `generator`, `locale`, and `source`, the `.po` file the strings came from.

A key is the string's `msgctxt`: a stable snake_case id that the app
generators use as the resource name, so rewording a string never renames its
resource. The status keys (`target_status_on_track` and the others) match the
status enums the API sends. gettext's `%{name}` placeholders become `{name}`,
a neutral form each app's generator maps to its own format. A `one` plural
form may leave out `{count}`. Keys are sorted at every level so the files diff
cleanly.

The status labels and the risk explainer sentence read the same as the web's
default domain in every locale, and the test fails when the two differ. Change
both copies together, or give the app string its own wording on purpose.
