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

5. Commit the `.po` files, these copies and the iOS string catalog in the same
   task. `mix mobile.strings` writes the catalog too, from the same strings:
   `mobile/ios/Stride/Resources/Localizable.xcstrings`. It leaves out plurals and
   strings with a placeholder, and names zh `zh-Hans` as iOS does.

`test/kanban/mobile/strings_test.exs` fails while a copy is stale, and when a
string is missing, empty, fuzzy or loses a placeholder in any locale. The
Elixir CI workflow skips a pull request confined to `mobile/`, so run that
test locally before committing one. See sections 14 and 17 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## What each file holds

- `strings`: `key => text` for each singular string.
- `plurals`: `key => {category => text}`, keyed by the CLDR plural category
  each platform's plural resources use. de, en, es, fr and pt have `one` and
  `other`; ja and zh have `other` only. The categories come from the locale's
  `Plural-Forms` header. The apps pick a form by CLDR's rules, which agree
  with gettext's for every count except pt at 0: CLDR reads 0 as `one`, so
  the apps show "0 meta" where gettext would show "0 metas". CLDR also has a
  `many` category for es, fr and pt at a million and up; no file has one, so
  both platforms fall back to `other`, which reads correctly.
- `generator`, `locale`, and `source`, the `.po` file the strings came from.

A key is the string's `msgctxt`: a stable snake_case id that the app
generators use as the resource name, so rewording a string never renames its
resource. The status keys (`target_status_on_track` and the others) match the
status enums the API sends. gettext's `%{name}` placeholders become `{name}`,
a neutral form each app's generator maps to its own format. A `one` plural
form may leave out `{count}`. Keys are sorted at every level so the files diff
cleanly.

The status labels and the risk explainer strings read the same as the web's
default domain in every locale, and the test fails when the two differ. Change
both copies together, or give the app string its own wording on purpose. The
plurals (`target_task_progress`, `target_goal_count`, `targets_at_risk_count`,
`goals_open_count` and `goal_archived_count`) are the app's own: the Targets,
Goals and goal screens in sections 6.16 to 6.19 of the design say things no
web page does. They use the web's words for each term in every locale, such as
de *Ziele* for goals and *Zielvorgaben* for targets.

The `update_required_*` strings are the app's own too, for the Update required
screen in section 7.2. A string with no web page that says the same thing is
listed in `@app_only` in `test/kanban/mobile/strings_test.exs`.
