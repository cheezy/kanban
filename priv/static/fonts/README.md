# Self-hosted fonts

This directory holds the three typefaces `assets/css/app.css` declares with
`@font-face`:

- **Geist** is `--font-sans` in the `.stride-marketing` scope (the marketing
  pages, and the nav on every page) and the `.stride-screen` scope (the
  signed-in app screens).
- **Geist Mono** is `--font-mono` in the same two scopes (`.ucase`, `.ident`,
  `.kbd` and the like).
- **Silkscreen** is `--font-pixel`, the pixel face of the printed handout, used
  only by `/HitMe`.

They are served from the site itself so that no page asks a third-party font
host for anything: a visitor's IP address and User-Agent never leave the site
for fonts, and the CSP (`KanbanWeb.Plugs.CspNonce`) allows fonts and styles only
from `'self'` (D402). A browser downloads a file only when a page renders that
face.

All three are under the SIL Open Font License 1.1, which allows bundling and
redistribution. Each licence text ships beside its files, and neither declares
a Reserved Font Name.

| File | Family | Weights | Upstream source | Conversion | sha256 | Licence |
|---|---|---|---|---|---|---|
| `Geist-Variable.woff2` | Geist | variable, wght axis 100–900; declared `300 700` | [vercel/geist-font](https://github.com/vercel/geist-font) v1.9.0 (commit `72f67167dd304a842ef8899da57fa25c5cf21756`), `fonts/Geist/webfonts/Geist[wght].woff2` | none (renamed only) | `2ffebe993e969069a9789d15164b7715d42491b5835516c5e3b935d5f81b05f1` | `Geist-OFL.txt` |
| `GeistMono-Variable.woff2` | Geist Mono | variable, wght axis 100–900; declared `400 600` | vercel/geist-font v1.9.0 (same commit), `fonts/GeistMono/webfonts/GeistMono[wght].woff2` | none (renamed only) | `afaacc4c5fbba89d2ebf7a02dc4070208540874592a5504d57175782fe893101` | `Geist-OFL.txt` |
| `Silkscreen-Regular.woff2` | Silkscreen | 400 | [google/fonts](https://github.com/google/fonts) commit `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`, `ofl/silkscreen/Silkscreen-Regular.ttf` (upstream googlefonts/silkscreen `206ccf3f5234c281461e63ecc59cbc6b0563472b`) | TTF to woff2, fontTools 4.68.0 + brotli 1.2.1, no subsetting | `a8509db65e47b89daa545d8c9e0b4ffaf0e153fa19d754ec9d4a3a13878d77a9` | `Silkscreen-OFL.txt` |
| `Silkscreen-Bold.woff2` | Silkscreen | 700 | google/fonts (same commit), `ofl/silkscreen/Silkscreen-Bold.ttf` | as above | `eb1e8471d5e81886e7bd12ea8bcd2564d27f3e3dddb7820a25c034b5afd7bf4e` | `Silkscreen-OFL.txt` |
| `Geist-OFL.txt` | — | — | vercel/geist-font v1.9.0, `OFL.txt` | verbatim | `c683bfbcc7e087f5d37a54ef628f10387c451a83ddc459b151403a164ac46c90` | — |
| `Silkscreen-OFL.txt` | — | — | google/fonts (same commit), `ofl/silkscreen/OFL.txt` | verbatim | `86c5e9c9382cdcc5948704fdfe60f2aa164a719746931219a42736ecd9cefbd3` | — |

The declared Geist ranges are the weights the app uses (400, 500, 600 and 700,
plus 300 at no extra cost because it is the same file), so the browser never
synthesises a bold. No italic is shipped; the app has never loaded one.

The Silkscreen conversion is an unmodified format change of the upstream TTF:

```sh
fonttools ttLib.woff2 compress -o priv/static/fonts/Silkscreen-Regular.woff2 Silkscreen-Regular.ttf
```

## Updating

Fetch from the project's official repository pinned by commit, never from a
font CDN. Then recompute the hashes with
`shasum -a 256 priv/static/fonts/*.woff2 priv/static/fonts/*.txt`, update the
table above, and update the `@font-face` weight ranges in `assets/css/app.css`
if the weights in use change.

`test/kanban_web/self_hosted_fonts_test.exs` fails when an `@font-face` URL
points at a missing file, when app.css names a Google Fonts host or imports a
remote stylesheet, when a rule lacks `font-display: swap`, when a weight app.css
sets falls outside the declared Geist range, when a file here is not declared,
not listed in this table or has no licence beside it, when a hash in this
table no longer matches its file, and when `phx.digest` stops listing a file in
its cache manifest or rewriting its url in the digested app.css.

Like everything under `priv/static`, this file is served publicly.
