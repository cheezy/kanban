# Stride for iOS and iPadOS

The rules in [../CLAUDE.md](../CLAUDE.md) apply here too. This file adds the
iOS and iPadOS ones. Section 12 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md)
has the platform choices behind them.

- **Support both themes.** Use the generated asset-catalog colours, which carry a light and a dark value, and check every screen in both appearances before you finish.
- **Ship all seven locales.** Show every string through the Xcode string catalog generated from the `mobile` gettext domain, in de, en, es, fr, ja, pt and zh. Check layouts at the largest text size in German, where labels run longest.
- **Label everything for accessibility.** Give every control a VoiceOver label, support Dynamic Type up to the accessibility sizes, keep touch targets at least 44 points, and run `performAccessibilityAudit()` in the UI tests.
- **Keep business logic out of views.** SwiftUI views render `@Observable` view models and nothing more. The API client, auth, cache, live channel and push registration belong in `StrideKit`, which the app and its extensions share, and view models depend on protocols so previews and tests run against `mobile/shared/fixtures/`.
- **Regenerate after changing a source.** After the API contract changes, regenerate the Swift client with `mix mobile.api`; after the tokens or strings change, run `mix mobile.tokens` or `mix mobile.strings`. Never edit generated files by hand.
- **Never commit the Xcode project.** The `.xcodeproj` is generated from `project.yml` and is ignored; change `project.yml` instead. Build output, `DerivedData` and per-user Xcode state are ignored too.
- **Never commit signing material.** Certificates (`.p12`), App Store Connect keys (`.p8`) and provisioning profiles stay out of the repository.
- **Keep the names CI uses.** [ios.yml](../../.github/workflows/ios.yml) generates `Stride.xcodeproj` from `project.yml` and tests the `Stride` scheme on an iPhone and an iPad simulator. It runs Swift Testing in `StrideTests`, the snapshot tests in the `SnapshotTests` suite of `StrideTests`, and XCUITest in `StrideUITests`. It pins the Xcode version, the simulator OS and XcodeGen in its `env` block; change them there.
