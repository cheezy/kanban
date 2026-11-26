# Design tokens

Generated. `mix mobile.tokens` reads the `.stride-screen` tokens in
`assets/css/app.css`, the web's source of truth, and the apps' text styles in
`lib/kanban/mobile/type_scale.ex`, and writes [tokens.json](tokens.json): the
colour, gradient, shadow, font, radius, type and text style tokens both apps
use, with a light and a dark theme.

Never edit `tokens.json` by hand. Change `assets/css/app.css`, or
`lib/kanban/mobile/type_scale.ex` for a text style, then run

```bash
MIX_ENV=test mix mobile.tokens
```

and commit the result in the same task.
`test/kanban/mobile/tokens_test.exs` regenerates the file in memory and fails
while the committed copy is stale, and
`test/kanban/mobile/ios_design_system_test.exs` does the same for the iOS
files the task also writes. The Elixir CI workflow skips a pull
request confined to `mobile/`, so run that test locally before committing
one. See section 14 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## What the file holds

`themes.light` and `themes.dark` have the same groups, keyed by the token name
without its leading `--`:

- `color`: each colour has a `hex` and, when `app.css` writes it as oklch, the
  `oklch` source. A colour with an alpha has an eight-digit `#rrggbbaa` hex,
  alpha last as in CSS. Colours outside sRGB are clipped per channel, the way
  `mix dark_mode.contrast` measures them, so many hex values are the nearest
  sRGB colour rather than the exact one. Use the `oklch` value where a
  platform can show a wider gamut.
- `composite`: gradients and shadows as CSS strings, with each `var()`
  reference replaced by the same theme's value.
- `font`: the font stacks as CSS strings.
- `radius`: the `--r-*` radii in px.
- `type`: `font_size_px`, `font_size_narrow_px` (below 768px wide),
  `letter_spacing_em` and `line_height`.
- `text_style`: the apps' named text styles, such as `large-title`, `body` and
  `label`, from the Stride Mobile 1.0 design, because `app.css` has none. Each
  has a `family` (the font token, `font-sans` or `font-mono`), `size_pt`, a CSS
  `weight` from 400 to 700, `letter_spacing_em`, `line_height` and `uppercase`.
  Where a style uses the body's letter spacing or line height, the value comes
  from `type`. The apps' running text is 15 pt, while the web's body is 13 px.

A token the dark block does not set keeps its light value, so fonts, radii and
the type scale appear in both themes. There is no spacing group, because
`app.css` defines no spacing tokens. The dark-only `--stride-diff-*` colours
are not included: they have no light token. Keys are sorted at every level so
the file diffs cleanly.

## The iOS files

The same task writes two things into the iOS app from these tokens:

- `mobile/ios/Stride/DesignSystem/Colors.xcassets`: one colour set per colour,
  named as the token is, with the light value for any appearance and the dark
  value for the dark appearance, in sRGB. An eight-digit hex gives the alpha.
  Xcode makes a Swift symbol of each, so `ink-2` is `Color(.ink2)` and
  `st-blocked-soft` is `Color(.stBlockedSoft)`. A colour set whose token is
  gone is removed.
- `mobile/ios/Stride/DesignSystem/DesignTokens.swift`: the first family of
  `font-sans` and `font-mono` (Geist and Geist Mono, which the app bundles), the
  text styles as `DesignTokens.TextStyles`, which `StrideTextStyle` reads, and
  the radii. `font-pixel` is
  left out, because the app does not bundle it.

In the app, `DesignTokenTests` checks every colour asset against this file in
both themes, holds the asset pairs to the contrast floors of
[docs/dark-mode-contract.md](../../../docs/dark-mode-contract.md), and checks
`DesignTokens.swift` and every `StrideTextStyle` against the fonts, text styles
and radii here.
