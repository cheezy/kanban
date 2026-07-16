defmodule KanbanWeb.ResponsivePrimitivesTest do
  @moduledoc """
  W1397 — the lightweight responsive guard for the G283 responsive-audit goal
  ("Complete mobile and responsive design audit across all application pages").

  Several pages style their mobile responsiveness through CSS rules in
  `assets/css/app.css` rather than Tailwind utility classes, because the markup
  is inline-styled (the `.stride-screen` design-token components). Those rules
  are the load-bearing responsive primitives the audit (tasks W1384–W1396)
  established or relies on:

    * `.task-detail-layout` / `.task-detail-aside` — task detail two-column →
      stacked below 1024px (W1391 reuse of the pre-existing primitive).
    * `.goal-detail-layout` / `.goal-detail-aside` — goal detail sidebar stacks
      below 1024px (W1392).
    * `[data-goal-child-row]` — goal child-row grid collapses below 640px (W1392).
    * `[data-changelog]` — changelog markdown body breaks long inline code and
      scrolls wide tables (W1386).
    * `[data-auth-frame]` / `[data-settings-panel]` — auth + settings form
      controls hit the 44px touch target below 768px (W1387).
    * `[data-review-stats-strip]` — review stats strip drops its right-column
      divider in the 2-up mobile layout (W1395).
    * `.agents-header-band` / `.agents-trends-band` / `.agents-health-band` /
      `.agents-risk-band` / `.agents-trends-series` — the /agents header chrome
      compresses on short viewports so the pinned two-pane layout stays usable
      (W1716). These are height-tier primitives, not width ones.

  This is a deliberately simple, stable, substring-level guard (mirroring the
  layering of `mix dark_mode.scan` + `dark_mode_regression_test`): it flags the
  silent removal of a documented responsive primitive without the false-positive
  noise a generic fixed-width scanner would produce. It does not parse CSS or
  measure layout — the actual per-breakpoint rendering is verified manually per
  `docs/responsive-audit.md`.
  """
  use ExUnit.Case, async: true

  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  @primitives [
    ".task-detail-layout",
    ".task-detail-aside",
    ".goal-detail-layout",
    ".goal-detail-aside",
    "[data-goal-child-row]",
    "[data-changelog]",
    "[data-auth-frame]",
    "[data-settings-panel]",
    "[data-review-stats-strip]",
    ".agents-header-band",
    ".agents-trends-band",
    ".agents-health-band",
    ".agents-risk-band",
    ".agents-trends-series"
  ]

  test "every documented responsive primitive is still present in app.css" do
    css = File.read!(@app_css)

    for primitive <- @primitives do
      assert String.contains?(css, primitive),
             "Missing responsive primitive `#{primitive}` in assets/css/app.css — " <>
               "removing it regresses a mobile layout the responsive audit established. " <>
               "See docs/responsive-audit.md (Completed audit log)."
    end
  end

  test "the mobile-stacking media queries are present" do
    css = File.read!(@app_css)

    # The inline-styled two-column layouts stack below the lg breakpoint (1023px)
    # and the child-row grid slims below the sm breakpoint (639px).
    assert String.contains?(css, "max-width: 1023px"),
           "Missing the <1024px stacking media query (task/goal detail layouts)."

    assert String.contains?(css, "max-width: 639px"),
           "Missing the <640px media query (goal child-row mobile grid)."
  end

  test "the /agents height tiers keep compression above unpinning" do
    css = File.read!(@app_css)

    # Compression must engage at a TALLER viewport than the pin tier gives up
    # at, so the header chrome sheds density before the layout drops to
    # full-page scrolling. 800 > 700 — move them together or not at all.
    assert String.contains?(css, "max-height: 800px"),
           "Missing the /agents short-viewport compression media query."

    assert String.contains?(css, "min-height: 700px"),
           "Missing the /agents height-aware pinning media query."
  end
end
