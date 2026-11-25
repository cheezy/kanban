# Stride for iOS and iPadOS

The rules in [../CLAUDE.md](../CLAUDE.md) apply here too. This file adds the
iOS and iPadOS ones. Section 12 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md)
has the platform choices behind them.

`project.yml` describes the `Stride` app, the `StrideKit` package, the
`StrideWidgets` and `StrideNotificationService` extensions, and the two test
targets. The app's and the widget's views are placeholders that show no text,
because nothing generates the Xcode string catalog or the asset-catalog colours
yet. Add the first visible string or colour with that generator, not by hand.

- **Support both themes.** Use the generated asset-catalog colours, which carry a light and a dark value, and check every screen in both appearances before you finish.
- **Ship all seven locales.** Show every string through the Xcode string catalog generated from the `mobile` gettext domain, in de, en, es, fr, ja, pt and zh. Check layouts at the largest text size in German, where labels run longest.
- **Label everything for accessibility.** Give every control a VoiceOver label, support Dynamic Type up to the accessibility sizes, keep touch targets at least 44 points, and run `performAccessibilityAudit()` in the UI tests.
- **Keep business logic out of views.** SwiftUI views render `@Observable` view models and nothing more. The API client, auth, cache, live channel and push registration belong in `StrideKit`, which the app and its extensions share, and view models depend on protocols so previews and tests run against `mobile/shared/fixtures/`.
- **Regenerate after changing a source.** After the API contract changes, run `mix mobile.api` to check it and refresh `mobile/shared/openapi.json`, which the app build will turn into the Swift client with the Swift OpenAPI Generator; after the tokens or strings change, run `mix mobile.tokens` or `mix mobile.strings`. Never edit generated files by hand.
- **Never commit the Xcode project.** The `.xcodeproj` is generated from `project.yml` and is ignored; change `project.yml` instead and run `xcodegen generate`. Build output, `DerivedData` and per-user Xcode state are ignored too.
- **Use the iOS Stride hooks.** `./ios_dev.sh` at the repository root switches the Stride hooks to the set for this app: `test/ios_test.sh` runs the `Stride` scheme on a simulator and `test/ios_elixir_checks.sh` runs the Elixir tests that read `mobile/` before each task commit. [docs/hook-time-budget.md](../../docs/hook-time-budget.md) describes it, and `./stride_dev.sh` switches back.
- **Never commit signing material.** Certificates (`.p12`), App Store Connect keys (`.p8`) and provisioning profiles stay out of the repository.
- **Keep one copy of each identifier.** `project.yml` sets `STRIDE_BUNDLE_ID`, and the bundle ids, the app group and the keychain access group come from it as build settings. The entitlements grant both groups and each Info.plist names them, so Swift code reads them through StrideKit's `AppGroup` instead of repeating them. A new extension that shares data needs the same two entitlements and the same two Info.plist keys, and `EntitlementsTests` must list it.
- **Enable only the entitlements Phase 1 needs.** The app has the app group, the keychain access group, push and associated domains; the extensions have only the two groups. `EntitlementsTests` fails when a target gains another.
- **Keep the names CI uses.** [ios.yml](../../.github/workflows/ios.yml) generates `Stride.xcodeproj` from `project.yml` and tests the `Stride` scheme on an iPhone and an iPad simulator. It runs Swift Testing in `StrideTests` and in the StrideKit package's `StrideKitTests`, the snapshot tests in the `SnapshotTests` suite of `StrideTests`, and XCUITest in `StrideUITests`. All three targets must be in the `Stride` scheme's test action in `project.yml` (list the package's as `package: StrideKit/StrideKitTests`): naming a target the scheme lacks fails the run. It pins the Xcode version, the simulator OS and XcodeGen in its `env` block; change them there.
