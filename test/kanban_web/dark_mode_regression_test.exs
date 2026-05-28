defmodule KanbanWeb.DarkModeRegressionTest do
  @moduledoc """
  Catches dark-mode violations that the source-level `mix dark_mode.scan`
  Mix task can miss — anything emitted by a macro, a function component
  computing a class string, or a daisyUI helper that resolves to a theme-
  blind value only at render time. Walks the enumerated public + private
  routes, GETs each, and asserts the response body contains none of the
  forbidden patterns.

  This is the rendered-output complement to:

    * `mix dark_mode.scan` (W899) — source-level scanner
    * `tools/dark-mode-audit/audit.mjs` (W900) — runtime WCAG contrast audit
      via Playwright + axe-core

  Together the three layers form the W900-W909 verification stack: source,
  rendered HTML, and computed pixel contrast.
  """
  use KanbanWeb.ConnCase

  # Routes that do not require authentication. Each is GET-able with a
  # plain conn — public marketing surfaces.
  @public_routes [
    "/",
    "/about",
    "/pricing",
    "/privacy",
    "/product",
    "/security",
    "/workflows",
    "/changelog",
    "/users/log-in",
    "/users/register",
    "/users/forgot-password"
  ]

  # Routes that require a logged-in scope. Param-bearing routes (`/boards/:id`,
  # `/boards/:id/tasks/:task_id/edit`, etc.) are not included here — they
  # need per-test fixtures and are already exercised by the per-LiveView
  # tests under test/kanban_web/live/. This regression test focuses on the
  # static, well-known surface area.
  @authenticated_routes [
    "/boards",
    "/boards/new",
    "/agents",
    "/review",
    "/metrics",
    "/resources",
    "/users/settings"
  ]

  # Forbidden class patterns. These mirror `Mix.Tasks.DarkMode.Scan`'s
  # regex set — keep them in sync. A render-time match means a macro or
  # function component is emitting a theme-blind class even though it
  # doesn't appear literally in any source file.
  @class_violation_pattern ~r/(?<![\w-])(text-gray-\d+|bg-gray-\d+|border-gray-\d+|bg-white|text-white|text-black|bg-black)(?![\w-])/

  @inline_oklch_pattern ~r/style="[^"]*\boklch\s*\([^"]*"/
  @inline_hex_pattern ~r/style="[^"]*#[0-9a-fA-F]{3,8}\b[^"]*"/

  # Allow-list for legitimate marketing brand markers and the mobile-drawer
  # backdrop overlay that have been intentionally surfaced through the
  # dark_mode.scan allow-list comments and survive into the rendered HTML.
  # Keep this list aligned with the inline `dark-mode-ignore` comments in
  # the source.
  @allowlisted_substrings [
    # Mobile drawer backdrop overlay (layouts.ex:69)
    "bg-black/40",
    # Megaphone badge in board show (show.html.heex:62) — white text on a
    # fixed gradient
    "rounded-xl shrink-0 text-white",
    # Marketing-mini-board brand status dots (red/yellow/green) — fixed
    # contrast on both themes
    "background: oklch(75% 0.13 25)",
    "background: oklch(80% 0.13 80)",
    "background: oklch(70% 0.14 145)",
    # Stride brand drop-shadow on the megaphone badge — fixed-color glow
    "oklch(50% 0.18 47",
    # Stride brand border on the workspace-message card
    "oklch(85% 0.12 50",
    # Box-shadow on the megaphone badge container
    "oklch(50% 0.1 47",
    # Avatar palette colors — fixed medium-saturation hues that don't flip
    # with theme (W900/W902 — see avatar.ex:148+ palette + the inline dark
    # text override that gives consistent ~5:1 contrast on every palette).
    "oklch(60% 0.10 240)",
    "oklch(60% 0.10 60)",
    "oklch(60% 0.10 155)",
    "oklch(60% 0.10 320)",
    "oklch(70% 0.16 47)",
    "oklch(60% 0.16 240)",
    "oklch(60% 0.14 155)",
    "oklch(60% 0.18 277)",
    # Avatar initials text color — intentionally theme-blind (W900).
    "color: oklch(18% 0.005 270)",
    # Auth-frame editorial gradient (auth_frame.ex) — locked-light brand
    # entry surface per the .stride-screen[data-stride-auth-frame] override
    # in assets/css/app.css:898+; the gradient is part of the brand identity.
    "oklch(96% 0.025 60)",
    "oklch(94% 0.035 280)",
    # Auth-frame primary_full_button gradient (orange→violet) and any other
    # auth-frame branded fixed colors.
    "oklch(68% 0.17 47",
    "oklch(60% 0.18 277"
  ]

  describe "public routes" do
    for route <- @public_routes do
      test "#{route} renders no theme-blind classes or literals", %{conn: conn} do
        conn = get(conn, unquote(route))
        body = response(conn, 200)
        assert_no_violations(unquote(route), body)
      end
    end
  end

  describe "authenticated routes" do
    setup :register_and_log_in_user

    for route <- @authenticated_routes do
      test "#{route} renders no theme-blind classes or literals", %{conn: conn} do
        conn = get(conn, unquote(route))
        body = response(conn, 200)
        assert_no_violations(unquote(route), body)
      end
    end
  end

  describe "scanner self-check" do
    test "the violation patterns flag a synthetic offender" do
      synthetic = ~s|<div class="bg-white"><span style="color: #fff;">x</span></div>|

      assert match?({:error, [_ | _]}, find_violations(synthetic))
    end

    test "the violation patterns ignore allow-listed brand markers" do
      synthetic = ~s|<span style="background: oklch(75% 0.13 25);">brand</span>|

      assert find_violations(synthetic) == :ok
    end
  end

  defp assert_no_violations(route, body) do
    case find_violations(body) do
      :ok ->
        :ok

      {:error, violations} ->
        flunk("""
        Theme-blind violations in #{route}:
        #{Enum.map_join(violations, "\n", &"  - #{&1}")}
        If a violation is intentional, add the substring to @allowlisted_substrings.
        """)
    end
  end

  defp find_violations(body) do
    body_without_allowlisted =
      Enum.reduce(@allowlisted_substrings, body, fn substring, acc ->
        String.replace(acc, substring, "")
      end)

    violations =
      []
      |> collect(@class_violation_pattern, body_without_allowlisted, "Tailwind theme-blind class")
      |> collect(@inline_oklch_pattern, body_without_allowlisted, "Inline oklch() literal")
      |> collect(@inline_hex_pattern, body_without_allowlisted, "Inline hex color literal")

    case violations do
      [] -> :ok
      _ -> {:error, violations}
    end
  end

  defp collect(acc, pattern, body, label) do
    case Regex.scan(pattern, body) do
      [] -> acc
      matches -> Enum.map(matches, &"#{label}: #{snippet_of(&1)}") ++ acc
    end
  end

  defp snippet_of([full | _]), do: full
end
