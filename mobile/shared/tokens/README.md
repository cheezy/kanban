# Design tokens

Generated. `mix mobile.tokens` reads the `.stride-screen` tokens in
`assets/css/app.css`, the web's source of truth, and writes
[tokens.json](tokens.json): the colour, gradient, shadow, font, radius and
type tokens both apps use, with a light and a dark theme.

Never edit `tokens.json` by hand. Change `assets/css/app.css`, then run

```bash
MIX_ENV=test mix mobile.tokens
```

and commit the result in the same task.
`test/kanban/mobile/tokens_test.exs` regenerates the file in memory and fails
while the committed copy is stale. The Elixir CI workflow skips a pull
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

A token the dark block does not set keeps its light value, so fonts, radii and
the type scale appear in both themes. There is no spacing group, because
`app.css` defines no spacing tokens. The dark-only `--stride-diff-*` colours
are not included: they have no light token. Keys are sorted at every level so
the file diffs cleanly.
