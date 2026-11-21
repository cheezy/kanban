# Design tokens

Generated. `mix mobile.tokens` reads the `.stride-screen` tokens in
`assets/css/app.css`, the web's source of truth, and writes the colour and type
tokens both apps use, with a light and a dark value for each colour. An ExUnit
test regenerates them in memory and fails when the copy here is stale.

Never edit these files by hand. Change `assets/css/app.css`, run
`mix mobile.tokens` and commit the result in the same task. See section 14 of
[docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md](../../../docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).
