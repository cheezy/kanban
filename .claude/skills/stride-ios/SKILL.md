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
- To run some tests only, name them after the options:
  `MIX_ENV=test mix ios.test --simulator <UDID> StrideUITests/ShellUITests`.
  The task has no `--only` option (W2790).
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
  counts one toward the ABC size, so keep each list in `strings/msgids.ex` to about 15
  strings, and rerun `MIX_ENV=test mix gettext.extract --merge` and
  `mix mobile.strings` after moving one, since the `.pot` records line numbers.
- `after_doing` commits with `git add -A`, so any untracked file not in
  `.gitignore` lands in the task commit. Keep scratch copies and notes in the
  session scratchpad.
- A completion the server refuses with a 422 has already run `after_doing`, so
  the task commit is made, merged into main and its branch deleted. Fix the
  payload and send it again from main; build every required field (the
  reviewer's integers, `actual_files_changed` from the commit range) before the
  first send (W2794).
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
  `dpngettext_noop` for a count) to `Kanban.Mobile.Strings.Msgids.msgids/0` in
  `lib/kanban/mobile/strings/msgids.ex`, run `MIX_ENV=test mix gettext.extract --merge`,
  translate it in all seven `priv/gettext/<locale>/LC_MESSAGES/mobile.po` files
  with no fuzzy flag, run `MIX_ENV=test mix mobile.strings`, and commit all of it.
- `test/kanban/mobile/strings_test.exs` pins the number of strings and plurals
  and the count of keys shared with the web domain. A key the web lacks goes in
  its `@app_only` list; bump the counts in the same change.
- A key whose msgid the web's `default` domain also has must read exactly as the
  web's translation in every locale, so copy those (grep `priv/gettext/<locale>/
  LC_MESSAGES/default.po`) instead of translating afresh. A new msgctxt whose
  msgid another mobile key already has comes out of `gettext.extract --merge`
  fuzzy with the old text; set its msgstr and drop the flag (W2790).
- The brand name "Stride" is the `sign_in_title` key; use `Text(.signInTitle)`
  rather than a verbatim string (W2790).
- The msgid lists moved out of `strings.ex` into `strings/msgids.ex` when
  `strings.ex` passed 600 lines; `Strings.msgids/0` delegates there, and the
  generated `L10n.swift` header names the new file (W2794).
- Editing `lib/kanban/mobile/strings/msgids.ex` is a change outside `mobile/`, so the
  task's `after_doing` runs the whole Elixir suite and credo (see Hook modes).
  Add a string to an existing `*_msgids` helper, or add a new helper to the
  list `msgids/0` passes to `Enum.concat/1`; a chain of `++` there went over
  credo's ABC size limit at eleven helpers (W2793).

## Design

- The design is the Stride Mobile 1.0 artifact. A session's copy of its files may
  be cached under the scratchpad (`artifact-files/092b31aa-.../project/`);
  otherwise read it with the Artifact tool. `stride-mobile.css` holds the
  component specs, and the artboards (Main, Review, TabletReview, Targets,
  Agents and others) show each screen. `Diff.dc.html` is not published; the diff
  lines are in TabletReview.
- **Keep the design artifact current.** The artifact must always show the app
  as built plus what is still planned. When a task builds a screen or component
  differently from its artboard (layout, placement, a control, a state the
  design lacks), update the artifact's files in the same task and republish it
  to the same URL, reading the live version first; leave unbuilt parts as
  designed. Name the changed artboards in the completion notes (user request,
  W2790).
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
- `FixtureAPI(isOffline:)` takes a `@Sendable` closure read on every request,
  so a test can take the device offline part way through, with an
  `OSAllocatedUnfairLock<Bool>` as the switch; `unreachable:` fails chosen
  operations from the start (W2790).
- A UI test audits dark mode by setting `XCUIDevice.shared.appearance = .dark`
  and putting the old value back in `addTeardownBlock`, since the simulator
  keeps it after the test (W2790).
- The test bundle carries `mobile/shared/strings` and `mobile/shared/tokens`
  but not the fixtures; `FixtureAPI` reads `mobile/shared/fixtures` through
  `#filePath` and exists only in debug builds.
- To edit a fixture for one test, `StrideTests/Support/DecisionFixtures.swift`
  reads it through `FixtureAPI.fixture(named:)` (internal, so `@testable import
  StrideKit`), changes the JSON object and decodes it through the client, so the
  test reads exactly what the app would (W2793).
- To hold an answer while something else lands, block `FixtureAPI(isOffline:)`'s
  closure on a `DispatchSemaphore` and signal it once the other event has shown;
  the closure runs off the main actor, so the test's main-actor waits still run
  (`NowModelTests.liveDuringReloadKept`, W2793).
- `FixtureAPI(answering:)` picks a body at send time from the operation id;
  nil falls through to `replacing:` and then the fixture. Use it when one test
  needs different answers from the same operation, such as a queue before and
  after a review is decided elsewhere (`ReviewQueueModelTests`, W2795).
- `DecisionFixtures.reviewsData(editingItems:)` edits `listMyReviews`, whose
  `data` is a bare array, as `data(editingItems:)` edits `listMyDecisions`'
  `data.items` (W2795).
- A new lazy list of cards joins `lazyLists` in `AccessibilityAudit.swift`, and
  its rows reuse the `card-identifier` and `card-age` identifiers, so the
  existing audit filters (`isUnderBarsContrast`, `isOnLazyCard`,
  `isOnCardMonoText`) cover it with no new filter (the Review queue, W2795).

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
  first. On an iPad the contrast audit fails a lone mono digit from a tight
  crop although its pair passes: the attempt sheet's exit code "1" is `ink` on
  `surface`, and a Now filter count is `ink-3` (`ink-2` when selected) on
  `surface-sunken`. Read the failed test's "Element Screenshot" with `xcrun
  xcresulttool export attachments` to see which text it judged, then ignore
  only that element by an identifier on its container, as `isOnNowFilterCount`
  and `isOnAttemptRowValue` do (W2794). iOS 26 reports some SwiftUI `Link`s as buttons, so a UI test finds a
  link as a link or a button (commit 7975ed01).
- A failed audit says only "Contrast failed for SwiftUI.AccessibilityNode". To
  see which element, export the run's attachments with `xcrun xcresulttool
  export attachments --path <xcresult> --output-path <dir> --test-id
  '<Suite>/<test>()'`; the "Element Screenshot" image shows the element. Give it
  an identifier and ignore only that issue, with its measured contrast. When
  many elements fail at once, list them all in a scratch copy of the test with
  `performAccessibilityAudit(for: .contrast) { print(...); return true }`; the
  audit stops at the first failure otherwise. In W2793 every text in the cards
  failed because `.shadow` sat on the whole card; shadowing only the
  background shape fixed it (W2793).
- A scratch test's `print` does not reach the `xcodebuild` log; write the
  dumped issues to a file in the scratchpad instead, which the simulator can
  reach (W2793).
- The audit's Dynamic Type check reports as "partially unsupported": text in a
  style that follows `caption2`, which stops shrinking at 11 points (the
  `label` style now follows `caption`); and every element of a `LazyVStack`
  row that its larger text pushes off the screen, because the lazy stack lets
  go of the row. Prove the second by swapping in a `VStack` in a scratch copy.
  "Hit area is too small" fires on any small element with its own label that is
  not text; the `.isStaticText` trait fixes a dot or pill that is not a
  control (W2793).
- The contrast check measures pixels, so thin small text can fail on an iPad
  (2x) and pass on an iPhone (3x): the Now filter's 11-point mono count in
  `ink-3` on `surface-sunken` failed there though the tokens reach 5:1, and
  still failed in `ink-2` (about 9:1), because the audit judges it from a
  7-by-16-point crop. A darker ink does not fix that: ignore such an issue
  narrowly, by its frame and text, as `isOnNowFilterCount` does, or by an
  accessibility identifier, as `isOnCardMonoText` does for the cards' "D21"
  identifiers, and run the UI tests on the iPad before calling an audit fix
  done (W2793).
- The iPad (A16) shows the split view's sidebar upright and on its side, and
  iOS 27's audit fails the contrast of one sidebar row title or another from
  run to run (the Now row with its count on its side, the Review row upright),
  as iOS 26 did in dark; `isOnSidebarRow` ignores only the titles and the
  count, whose token pairs a unit test holds. An `.accessibilityHidden` text
  still shows in XCUI's tree and in audit issues. Dump the issues'
  identifiers in a scratch copy before writing an ignore, rather than
  guessing from the element screenshot (W2793).
- The simulator keeps the rotation a screenshot session left, and the home
  screen looks the same upright and upside down: open the app and take a
  screenshot to see which way up it is before a UI test run. An upside-down
  iPad fails the audits like an upright one (W2793).
- `xcodebuild build-for-testing` alone did not report the strict-concurrency
  errors in the test files that `mix ios.test` then failed on (W2793); trust
  only a full `mix ios.test` run.
- `SignInUITests.testFitsTheLargestTextInGerman` can still flake on the iPad in
  a full run with "Potentially inaccessible text"; rerun
  `StrideUITests/SignInUITests` alone before suspecting the change (W2792).
- An iPadOS sidebar `List(selection:)` sometimes fills the selected row with
  the tint and draws white text on it, and other times greys it, so the audit
  passes one run and fails the next. In dark the tint `stride-orange-ink` is
  light, and white on it is about 1.6:1. Draw the selection yourself, as the
  design's `.side a.on` does: rows as plain buttons, `stride-orange-ink` on a
  `stride-orange-soft` row background, and the `.isSelected` trait (W2790).
- To see which element an audit flagged, export the failure's attachments:
  `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>
  --test-id "ShellUITests/<test>()" --only-failures`. The xcresult path is in the
  `mix ios.test` output; the export holds the issue text and screenshots of the
  app and the element (W2790).
- Text inside a navigation-bar toolbar item does not grow with Dynamic Type, so
  the audit reports "Dynamic Type font sizes are partially unsupported" for it
  (the avatar's initials, W2790). Put such controls in the screen, as the
  design's corner row does, and hide the bar on the tab's first screen.
- A text bar button on iOS 26 and 27's glass fails the contrast audit even in
  `ink`, black on white to the eye ("Contrast failed for
  SwiftUI.AccessibilityNode"), so a sheet's Close button sits in the sheet's
  content with its title, as `ShellSheetView` does (W2790). The audit's element
  screenshot is in the xcresult: `xcrun xcresulttool export attachments
  --path <xcresult> --output-path <dir> --test-id "<Suite>/<test>()"`.
- On iOS 26 and 27 a tab bar item reports its SF Symbol name ("tray") as its
  identifier, so find a tab by its label, matching the start because Now's label
  may carry the badge (W2790).
- A `NavigationSplitView` sidebar row is a `Cell` with no label; its text is a
  child `StaticText` (with the badge as its value). Find it with
  `app.cells.staticTexts`, and a phone's tab with `app.tabBars.buttons`
  (W2790).
- In a sidebar, a list `.badge` fails the contrast audit on the selected row
  (faint as standard, white on red with `.badgeProminence(.increased)`). On a
  row that is not selected the audit also fails any count drawn in it (black on
  grey, and an ink-on-surface pill alike), and the row's own `StaticText`, whose
  frame is the whole cell; a longer settle changed nothing, and
  `.accessibilityHidden` does not keep the count out of the audit. `AppShell`
  draws an ink-on-surface pill (`sidebar-count`), gives the tab's label the
  count as its `accessibilityValue`, and `ShellUITests.ignoringSidebarIssue`
  ignores contrast only on that pill and on the `sidebar-tab` row with a
  value, selected or not: on iOS 27.2 the selected Now row fails too. On iOS
  26.4 in dark the audit also fails a plain unselected row (white on near
  black) below the selected one, though 27.2 passes it and a 2-second settle
  changed nothing, so that ignore checks `UIDevice.current.systemVersion` and
  `XCUIDevice.shared.appearance`. CI runs iOS 26, so run a new UI audit on the
  26.4 simulators in both appearances (W2790).
- While a split view's detail column shows its navigation bar, the contrast
  audit fails the sidebar's selected row even without a count. But hiding the
  detail bar always leaves no way back once the sidebar toggle hides the
  sidebar, since the toggle then lives in that bar. `AppShell` binds
  `columnVisibility` (start it at `.all`: `.automatic` starts an upright iPad
  with the sidebar hidden) and shows the detail bar (`showsDetailBar`) only
  while it is `.detailOnly` (W2790). Combining the row with `.accessibilityElement(children:
  .combine)` moved the "text clipped" report to an element without the
  identifier (W2790).
- To see what an audit issue is about, print `issue.auditType.rawValue`,
  `issue.detailedDescription` and `issue.element?.debugDescription` in the
  handler; `mix ios.test` filters prints, so read them in
  `mobile/ios/build/ios.test.log` (W2790).
- On an iPad a form sheet leaves the screen behind it dimmed and out of
  VoiceOver's reach, and the audit reports that text as "Potentially
  inaccessible text" (`.elementDetection`) with a nil element. `ShellUITests`
  ignores only that issue, only on an iPad (W2790).
- The audit's Dynamic Type pass reports a sidebar row as "Text clipped" on
  every run, though the same rows at the largest size pass. `ShellUITests`
  ignores `.textClipped` on the `sidebar-tab` identifier only (W2790).
- A tab's first screen in a split view's detail column takes only the width of
  its content, so its background is a narrow strip and its title centred: give
  the content `.frame(maxWidth: .infinity, alignment: .leading)`, as `TabRoot`
  does (W2790).
- A `SignInModel` built with `phase: .starting` and no services moves itself to
  signed out as soon as the root view's task runs; a drawing that needs the
  blank screen uses `.signedIn(.checking)` (W2790).
- A key path cannot use `Dictionary`'s `subscript(_:default:)`, so
  `$model.paths[tab, default: []]` does not compile; give the state a type with
  a plain subscript, as `TabPaths` does (W2790).

## Cache and SwiftData

- StrideKit's `Cache` (W2791) keeps JSON payloads in one generic SwiftData
  entity rather than typed models, so an API change needs no migration; a
  payload a build cannot decode reads as nil and is deleted.
  [docs/ios-cache.md](../../../docs/ios-cache.md) has the design.
- The app supports iOS 17, so `#Unique`, `#Index`, `ModelContainer.deleteAllData()`,
  `Mutex` and AsyncSequence primary associated types are out without
  `#available`; this Mac has no iOS 17 runtime, so only the compiler checks it.
- `ModelContainer` is Sendable and a `ModelContext` is not: open a fresh context
  inside each synchronous actor method and never let it or a model leave. A plain
  actor is used instead of `@ModelActor`, which on iOS 17 runs on the main queue
  when made there.
- Keep `AsyncStream` tests deterministic with `.bufferingNewest(1)`: a source
  that yields several states before the reader starts delivers only the last,
  so drive each change after the reader has taken the previous one. The same
  buffer hides a missing de-duplication: a repeat reported just before a change
  is overwritten either way. Report the repeat alone while the reader waits and
  the change a moment later (W2791's break-it run caught a test that missed this).
- A docs edit is outside `mobile/`, so a task that adds `docs/ios-*.md` runs the
  whole Elixir suite in `after_doing` (see Hook modes).

## Live updates

- The socket token from `POST /api/me/socket_token` works for one connect and
  60 seconds, so `LiveChannel` builds a new SwiftPhoenixClient `Socket` for each
  connect and lets the library reconnect nothing: its own reconnect resends the
  used token and is refused with a bare 403 (W2792).
- A revoke closes the socket with a plain 1000 and no message, so a client
  cannot tell it from a drop; it shows only when the next token request fails
  as `signedOut` (W2792).
- Test an actor that runs its own loop through injected closures (token, connect,
  pause, sign-out) and a fake connection the test sends events on, then wait
  with `eventually` from `FakeLiveServer.swift`, which polls every 10 ms, rather
  than sleeping a fixed time (W2792).
- SwiftPhoenixClient's `Message.payload` for a `phx_reply` is already the
  reply's `response`, so a join refusal's reason is `payload["reason"]`, not
  `payload["response"]["reason"]`. Test the socket code through the `Socket`
  initialiser's `transport:` closure with a fake `PhoenixTransport` that answers
  through its delegate with JSON arrays, not by mocking the library (W2792).
- An actor that keeps the last state it was sent (here `LiveChannel.latest`)
  must drop it on a sign-out, or the next person's first listener gets the last
  person's data; the review flagged it as a security finding (W2792).
- `listMyDecisions`'s items carry `summary` as an object; to make a second,
  different state from the fixture change `since` with `FixtureChange.firstItem`
  (W2792).
- A screen that both fetches and follows a channel needs a version counter: a
  fetch that set out before a live list arrived must not replace it, and a
  session counter drops anything that set out before a sign-out (`NowModel`,
  W2793).

## Decisions

- An item's `details` is an `anyOf` of five shapes, and their optional fields
  let more than one shape decode the same JSON, so pick `value1` to `value5` by
  the item's `kind`, never by the first that is non-nil (W2793).
- A `hook_failed` decision is a goal's `after_goal` attempt (identifier `G…`),
  so View attempt opens the goal; `claim_expired` items may have a null agent,
  and `ready_empty` items have no task, identifier, title or `since` (W2793).
- `approve` and `request_changes` are offered on review items but never shown
  on a Now card; they belong to the review screen, behind Face ID (W2793).
- The fixture's `web_url`s must be on the configured Stride host
  (`www.stridelikeaboss.com`), or `StrideWeb.isStridePage` refuses them and the
  card has no Open on web button; `listMyReviews.json` still names
  `stride.example` (W2794).
- A `hook_failed` card's `task_id` is its goal's id, so View attempt asks
  `getMyGoalAfterGoal` with it. The answer has no output field at all (W2794).
- To test an action's failure, give `FixtureAPI` a `statuses` entry with a
  replaced body that matches that status's schema (a 403 on a comment is
  `PlanRequired`, a 422 on a move is `MeTaskRefusal`); a status without a body
  the schema needs fails to decode and reads as a plain failure. `onSend`
  hears each operation with its request body, so a test can check what was
  sent (W2794).
- `Optional.map` takes no async closure, so collect an optional `HTTPBody`
  with `if let`, not `body.map { try await ... }` (W2794).

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
- Read a failed test's name from the log as the whole quoted string after
  `Test "`; cutting it at a word such as " with" also cuts "without" and turns a
  caught break into a false miss (W2792). Pick breaks that fail fast, such as
  yielding the wrong event, over ones that make a test wait for its time limit. A test stopped by its time limit logs `recorded an
  issue ... Time limit was exceeded` and may never print a `failed` line before
  the run ends, so a break-it parser must count that line as caught (W2791).

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
