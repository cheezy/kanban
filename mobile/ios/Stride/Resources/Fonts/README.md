# Bundled fonts

The app and its widgets bundle Geist and Geist Mono, the typefaces the web app
uses. Each target lists the files in `UIAppFonts`, and `FontTests` checks that
they register. Both are variable fonts with a `wght` axis from 100 to 900.

They are under the SIL Open Font License 1.1, which allows bundling. The licence
is copied into each bundle beside the fonts, and it declares no Reserved Font
Name.

| File | Family | Made from, in `priv/static/fonts/` | sha256 |
|---|---|---|---|
| `Geist-Variable.ttf` | Geist | `Geist-Variable.woff2` | `249dcaf96b7b6b5636e63553224afb00222a7d48fe5d2730e096872145d3f9ea` |
| `GeistMono-Variable.ttf` | Geist Mono | `GeistMono-Variable.woff2` | `2a5eba3757be6f47a8c3c1d13aa9e726c6d66a664cfe0edc293e62395cd742fc` |
| `Geist-OFL.txt` | — | `Geist-OFL.txt`, verbatim | `c683bfbcc7e087f5d37a54ef628f10387c451a83ddc459b151403a164ac46c90` |

iOS cannot load woff2, so the TTFs were rebuilt from the repository's own web
copies ([where those come from](../../../../../priv/static/fonts/README.md):
vercel/geist-font v1.9.0). Core Text decoded each woff2, its tables were written
into a TrueType file unchanged, and only the table directory and the `head`
checksum are new. Every glyph outline at weights 100, 400, 600 and 900 is
identical to the web copy.

## Updating

Update the web copies first, rebuild the TTFs from them or take them from the
same upstream commit, and update the hashes above.
`test/kanban/repository_layout_test.exs` fails when a hash does not match its
file.
