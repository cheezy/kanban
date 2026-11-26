---
name: stride-ios
description: Use when writing, testing, reviewing or completing any change under mobile/ios/ in the Stride repository (Swift, project.yml, string catalog, asset catalogs, StrideTests, StrideUITests, StrideKit). Holds the Stride-specific iOS knowledge the swiftui-pro, swift-concurrency-pro, swift-testing-pro and swiftdata-pro skills lack - the mix tasks and hook modes, generated files, simulators, the design artboards, Xcode and iOS version quirks, and the Stride review rules for iOS tasks. Load it alongside those skills, before the first change.
---

# Stride iOS

This skill adds what the general Swift skills cannot know about this repository
and this Mac. Load it together with the Swift skills that `~/.claude/rules/skill-routing.md`
names for the change. The rules files still come first:
[mobile/CLAUDE.md](../../../mobile/CLAUDE.md) and
[mobile/ios/CLAUDE.md](../../../mobile/ios/CLAUDE.md) say what the app must do;
this skill says how the work goes here and what has gone wrong before.

**Keep this skill current.** When an iOS task teaches something that is not in
the Swift skills or the CLAUDE.md files (a tool quirk, a failure and its cause,
a review rule, a design fact), add it to the matching section below in the same
task, as one or two plain sentences with the task id. Correct or delete a line
that has turned out wrong. Rules the app must follow belong in
`mobile/ios/CLAUDE.md`, not here.

## Commands

- Build and test from the repository root with the mix tasks, always in the test
  environment: `MIX_ENV=test mix ios.test --simulator <UDID>` and
  `MIX_ENV=test mix ios.deploy --simulator <UDID>`. Without `MIX_ENV=test` the
  task compiles the `:dev` build that the user's running server reads.
  [docs/ios-mix-tasks.md](../../../docs/ios-mix-tasks.md) has the options.
  `ios.deploy` opens no Simulator window unless `--open`.
- Pass a full UDID, never a name: a name can pick a simulator the user has not
  approved (see Simulators).
- Each task runs `xcodegen generate` first. After a hand `xcodegen` or
  `xcodebuild` run, every building `xcodebuild` call needs
  `-skipPackagePluginValidation`, because the OpenAPI generator is a build plugin.
- Wrap long runs in `timeout 900`, and run them in the background when they can
  pass two minutes. Run one simulator at a time; several at once overload this Mac.
- The full log of each run is in `build/`. In xcresult output and the logs a
  failed test's `✘` is written `\x{2718}`, so search for that, not the symbol.
- After changing `mobile/shared/` sources, run the generator in the test
  environment: `MIX_ENV=test mix mobile.strings`, `MIX_ENV=test mix mobile.tokens`,
  `MIX_ENV=test mix mobile.api`. Their staleness tests are in `test/kanban/mobile/`
  and `test/mix/tasks/mobile/`; run both folders, not just one.

## Hook modes

- `./ios_dev.sh` switches the Stride hooks to the iOS set and `./stride_dev.sh`
  switches back. In iOS mode `.stride.md` shows as modified; that is expected,
  so never commit or "fix" it.
- In iOS mode `after_doing` runs `MIX_ENV=test mix ios.test` on the iPhone
  simulator, then `bash test/ios_elixir_checks.sh`, then the task commit. It
  tests no iPad: run the iPad yourself before completing.
- `ios_elixir_checks.sh` stays fast only while every file changed against main is
  under `mobile/` (or is `ios.yml`). Any other file runs the whole partitioned
  Elixir suite plus `mix format --check-formatted`, `credo --strict` and sobelow,
  about 280 seconds. So keep an iOS task inside `mobile/` when it can be, and when
  it cannot, write Elixir that passes credo the first time: no nested calls
  (pipe instead), and functions under credo's ABC size limit of 20 (split a
  render function into helpers early). W2787 and W2788 each lost a completion
  attempt to credo, and so did W2789: each `dpgettext_noop` call in a msgid list
  counts one toward the ABC size, so keep each list in `strings.ex` to about 15
  strings, and rerun `MIX_ENV=test mix gettext.extract --merge` and
  `mix mobile.strings` after moving one, since the `.pot` records line numbers.
- `after_doing` commits with `git add -A`, so any untracked file not in
  `.gitignore` lands in the task commit. Keep scratch copies and notes in the
  session scratchpad.
- Hook results are in `.stride/.hook-result-after_doing.json`. A failure that
  names a test outside `mobile/` may be a known flake: rerun that file alone with
  the hook's seed before changing anything. `inbox_channel_test.exs:315` (an
  unexpected telemetry message) and `forwarded_headers_rate_limit_test.exs:63`
  (requests across a minute boundary) have flaked.

## Generated files

- Never edit these by hand or in Xcode: `Stride.xcodeproj` (from `project.yml`,
  ignored, never committed), `Stride/Resources/Localizable.xcstrings` and
  `Stride/DesignSystem/L10n.swift` (`mix mobile.strings`),
  `Stride/DesignSystem/Colors.xcassets` and `DesignTokens.swift`
  (`mix mobile.tokens`), `StrideKit/Sources/StrideKit/openapi.json`
  (`mix mobile.api`).
- The generators are Elixir modules in `lib/kanban/mobile/` (`StringCatalog`,
  `StringAccessors`, `IosDesignSystem`, `TypeScale`, `SwiftContract`), on
  purpose: a generated copy has an ExUnit staleness test. Write a new generator
  the same way rather than as a Swift script, even when a task names a script.
- A mix task test that calls a generator must pass a `root:` in a tmp dir, or it
  writes into the repository (W2787).
- The app's text sizes live in `lib/kanban/mobile/type_scale.ex` and reach
  Swift through `tokens.json`; never write a type size as a Swift literal.

## Strings

- Xcode's generated symbol for a catalog string is internal, so the test targets
  reach it through `@testable import Stride`.
- Xcode names no positional argument (`.targetRiskSlip(_:_:)`), so call the
  labelled accessor in `L10n.swift` for any string with arguments.
- The shared locale `zh` is `zh-Hans` in the catalog and in `.lproj` names.
- Status values arrive as API enums; map each to its `mobile` string in a view
  model.
- To add a string: add `dpgettext_noop("mobile", key, text)` (or
  `dpngettext_noop` for a count) to `Kanban.Mobile.Strings.msgids/0` in
  `lib/kanban/mobile/strings.ex`, run `MIX_ENV=test mix gettext.extract --merge`,
  translate it in all seven `priv/gettext/<locale>/LC_MESSAGES/mobile.po` files
  with no fuzzy flag, run `MIX_ENV=test mix mobile.strings`, and commit all of it.
- `test/kanban/mobile/strings_test.exs` pins the number of strings and plurals
  and the count of keys shared with the web domain. A key the web lacks goes in
  its `@app_only` list; bump the counts in the same change.
- Editing `lib/kanban/mobile/strings.ex` is a change outside `mobile/`, so the
  task's `after_doing` runs the whole Elixir suite and credo (see Hook modes).

## Design

- The design is the Stride Mobile 1.0 artifact. A session's copy of its files may
  be cached under the scratchpad (`artifact-files/092b31aa-.../project/`);
  otherwise read it with the Artifact tool. `stride-mobile.css` holds the
  component specs, and the artboards (Main, Review, TabletReview, Targets,
  Agents and others) show each screen. `Diff.dc.html` is not published; the diff
  lines are in TabletReview.
- Map a CSS token to Swift through the generated catalog: `--ink-2` is
  `Color(.ink2)`, `--st-done-soft` is `Color(.stDoneSoft)`, and a CSS type
  style is `.textStyle(.body)`. Radii come from `DesignTokens.swift`.
- Component facts from `stride-mobile.css`, for the shared views:
  - `.verdict`: 18 high, mono 10.5, upper case, with a dot. Pass is
    `st-done-soft` on `st-done`, fail is `st-blocked-soft` on `st-blocked`.
  - `.pill`: 20 high, 11.5 at weight 600, soft background with the status ink.
  - `.bar`: 8 high, segments 3 apart with radius 2, done, review and doing
    colours, empty segments `surface-sunken` with a `line-2` border. Its label
    reads like "4 done, 1 in review, 2 in doing, 2 to do" or "6 of 6 done".
  - `.av`: 36 square with radius 8, a circle for a person; agent colours claude
    oklch(72% .15 47), codex (70% .13 277), cursor (72% .12 240), aider
    (72% .12 155), person (76% .08 240); small 22, extra small 28.
  - `.code` and `.ln`: mono 12 on a 20 line, a 34-wide line-number column in
    `ink-4`, added lines `st-done-soft`, removed lines `st-blocked-soft`. Token
    colours: keyword `st-review`, function `st-ready`, string `st-done`,
    attribute `stride-orange-ink`.
  - `.notice` (the offline banner) is `st-doing-soft`.
  - `.dcard` (decision card): padding 14, radius 14, `line` border, small
    shadow; kind dot, "holds up N" pill, identifier, priority dot labelled like
    "Critical priority", title 16 at weight 500, small agent avatar, verdicts.
- The tokens have no diff or syntax colours: the web's `--stride-diff-*`
  colours are dark-only and left out of the generated set
  (`mobile/shared/tokens/README.md`). Map diff lines and highlighted spans onto
  status tokens as above, and check their contrast in both themes.
- The API's verdict status is `passed | failed | not_assessed | null`, so a
  verdict pill needs a not-assessed state even where the design shows two.
- The shared views (W2789) are in `Stride/DesignSystem/Views`, their content
  types in `Stride/DesignSystem/Models` and their samples in
  `Stride/Debug/SharedViewSamples.swift`. Reuse them on a screen rather than
  drawing a pill or a card again. Every colour they use is a `ColorToken`
  case; `SharedViewAccessibilityTests` checks each text ink on its background
  at 4.5:1, so a new ink or background goes in its `textPairs` too.
- Deliberate departures from the artboards, all for contrast in dark mode:
  avatar initials use each family's soft and ink pair instead of a solid fill
  (`stride-orange`, `stride-violet`, `label-blue`, `label-green`,
  `label-gray`), and diff line numbers use `ink-3` (or the status ink), not
  `ink-4`. The progress bar adds a `st-blocked` segment the design lacks.
- There is no caption text style; the pill's 11.5 points is `.footnote` made
  semibold.
- A `LocalizedStringResource` resolves in its own `locale`, the device's
  unless set. So that a German preview or test reads German, the views read
  `@Environment(\.locale)` and resolve each string in it with
  `resource.resolved(in: locale)` (`LocalizedStringResource+Locale.swift`), or
  set `resource.locale` as `SignInPoint` does.
- The Sign in and Update required screens still use system colours and fonts;
  move a screen to the tokens when a task next changes it.

## Simulators

- Each device the Claude app's simulator tool uses for the first time shows the
  user a consent prompt, which blocks them when they are away. Use only these
  approved devices for screenshots and taps, and reuse them for test runs:
  - iPhone 17, iOS 27.2: `87188572-876A-4E60-8006-88D450B95063` (the user's
    live panel; leave it in English at the normal text size when done)
  - iPad (A16), iOS 27.2: `D3ADE155-857E-4F58-9421-084941FD2180`
  - iPhone 18 Pro, iOS 27.2: `6181ED90-41ED-4B18-B15F-2BDCE941B603`
  - iPhone Duo, iOS 27.2: `36216F0B-E373-43FB-AD2D-7B865897C011`
  - iPhone 17, iOS 26.4 (CI repro): `65FEB951-BC19-4DB3-B21F-694E01C50091`
  - iPad (A16), iOS 26.4: `DAA6D668-0204-4934-BA97-63084A1DD624`
- Plain `xcodebuild` needs no consent, so `mix ios.test` runs on any simulator;
  only the simulator tool needs an approved one. Never work around the prompt.
- Boot a simulator with `xcrun simctl bootstatus <UDID> -b` before a run. A run
  that hangs with "Invalid connectionUUID" is a CoreSimulator boot hang, not a
  prompt.
- Shut down any simulator you booted for a scratch run, so the user does not
  find a stray one.
- A task's verification step may name an iPhone 16; use the approved iPhone 17
  and iPad (A16) instead and say so in the completion notes.
- Test and look at every changed screen on the iPad as well as the iPhone:
  upright and on its side, light and dark, the largest text size, German, and a
  narrow split view where the screen allows. German at the largest size can fit
  an iPad without scrolling, so check scrolling on a phone.

## Snapshot tests

- There is no snapshot library and no stored reference image. "Snapshot test"
  here means `Drawing` (`StrideTests/Support/Drawing.swift`): it hosts a view in
  a `UIWindow` at a given appearance, text size and size, draws it to a bitmap,
  and the test asserts on the pixels (`corner`, `darkest`, `lightest`,
  `drawnRows`, `drawnWidth`). Do not add a snapshot package for a task that says
  "snapshot"; extend `Drawing`.
- `drawnRows` and `drawnWidth` compare against the top-left pixel, so they only
  measure a view that does not paint the whole window.
- `Drawing` takes no locale; wrap the view in
  `.environment(\.locale, Locale(identifier: "de"))`, as the previews do.
- CI runs the drawing suites `SnapshotTests` and `SharedViewSnapshotTests`
  (W2789) on both iPhone and iPad: `ios.yml` skips them in its unit step and
  runs them alone in its Snapshot step. A new drawing suite under another name
  runs on the iPhone only unless `ios.yml` gets matching skip and only-testing
  lines, so put drawing tests in one of those suites or update the workflow and
  the "Keep the names CI uses" bullet of `mobile/ios/CLAUDE.md`.
- A view smaller than the window is centred in it, and a view taller than the
  window is cut off. To draw a component, pad it, give it a width, top-align it
  with `.frame(maxHeight: .infinity, alignment: .top)` and pass a tall
  `height:` (`SharedViewSnapshotTests` uses 2700; `drawHierarchy` draws nothing past about 8192 pixels, 2730 points at 3x);
  `lastDrawnRow` tells whether it reached the bottom. A card's shadow reaches
  5 points past its edge, so allow for it in a `drawnWidth` check. German's
  short time is "0:00", not "00:00": match times loosely.
- The drawing tests cannot see an ellipsis. To look at views, a temporary
  test (deleted before the task commit) can draw them with
  `UIGraphicsImageRenderer` into a PNG in the session scratchpad, which the
  simulator writes to directly; W2789 found a truncated agent name that way. A
  `Text` beside an image in an `HStack` truncates at the largest sizes unless it
  has `.fixedSize(horizontal: false, vertical: true)`.
- To prove text wraps rather than truncating, draw it at two widths and expect
  more drawn rows in the narrow one.
- The test bundle carries `mobile/shared/strings` and `mobile/shared/tokens`
  but not the fixtures; `FixtureAPI` reads `mobile/shared/fixtures` through
  `#filePath` and exists only in debug builds.

## Test side effects

- `AuthStoreKeychainTests` removes the app's install marker, which signs the
  simulator's app out.
- `UpdateRequiredUITests` taps the App Store link; a simulator has no App Store,
  so Safari stays open with "address is invalid". Close it and relaunch the app
  if the user's panel shows it.

## Versions

- CI (`.github/workflows/ios.yml`) pins Xcode 26.6 and iOS 26.5; this Mac has
  Xcode 27.2 and runtimes 27.2 and 26.4, and no iOS 17 runtime. Say in the
  completion notes that CI's Xcode was not run locally. Run the iOS 26.4
  simulators when a change touches UI tests or accessibility.
- iOS 26 and 27 report a contrast failure on plain text when a
  `performAccessibilityAudit` call also resizes text, because the screen is
  still scrolling; `app.auditAccessibility()` runs the contrast check alone
  first. iOS 26 reports some SwiftUI `Link`s as buttons, so a UI test finds a
  link as a link or a button (commit 7975ed01).

## Break-it checks

- Run deliberate breaks in a scratch copy of `mobile/` in the session scratchpad,
  with its own `xcodegen` and `xcodebuild test` and its own simulator, so the
  real tree stays readable for reviewers. Restore Elixir breaks byte for byte.
- A scratch copy keeps its derived data, and an incremental build never removes
  a deleted `.lproj`: after a break that renames a locale, `LocalizationTests`
  fails on every later break. Clean that copy's build or ignore that test there.
- Write the break-it list before the review, one break per test, and run them in
  one script (W2789's `bi89.py` pattern: a fresh copy per break, `-only-testing`
  on the changed suites, a baseline run first and a restored run last). In W2789
  it found a test whose sample never reached the clamp it claimed to check, and a
  parameterized test that only round-tripped its own raw values.
- Have the break script print the `: error:` lines when its baseline fails: in
  W2789 an `#expect(widths.reduce(0, +) + 3 * 4 == 312)` on `[CGFloat]` did not
  compile, and the last 4000 characters of the log hid why. Give such a sum a
  typed `let` first.
- A broken `AsyncStream` that never ends makes a run take minutes; use a time
  limit trait on such tests.

## Stride review rules for iOS tasks

- Stride's fix-path classifier matches only lower-case `test/` and `tests/`
  paths, so an edit in `StrideTests/`, `StrideKitTests/` or `StrideUITests/`
  counts as a code fix. A fix there alone still does not earn review round two;
  only a code-path fix, a critical finding or a security finding does.
- Never log, print or snapshot a device token, refresh token, approval key or
  signature, and never put one in a snapshot test's fixture data.
- Render server text as plain `Text` (no Markdown, no links): use
  `Text(verbatim:)` or a `String` value, never a `LocalizedStringKey` built from
  server text.
