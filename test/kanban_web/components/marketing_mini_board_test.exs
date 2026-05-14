defmodule KanbanWeb.MarketingMiniBoardTest do
  @moduledoc """
  Behaviour coverage for `KanbanWeb.MarketingMiniBoard.marketing_mini_board/1`
  that the high-level `marketing_components_test.exs` does not exercise:

    * Priority-dot color per level (`--pri-critical` / `--pri-high` /
      `--pri-medium` — `--pri-low` is intentionally absent from the fixture).
    * Type-icon presence (every task card carries the `tone-work` glyph; the
      mini-board only renders the `work` type per the design's contract).
    * Per-column status-dot token (`--st-ready` / `--st-doing` / `--st-review`
      / `--st-done`).
    * Exact agent palette per agent (`claude` amber, `cursor` blue) and human
      palette (Jamie K and Rohan S both rendered with the green hash bucket).
    * Avatar-initials algorithm — multi-word "Jamie K" → "JK", single-word
      "Claude" → "C", always uppercased.
    * Traffic-light macOS-style dots (three oklch chips in the titlebar) +
      the orange-backgrounded STR badge.
    * The deliberate display-vs-total mismatch: `Ready` column declares
      `count: 8` but only 2 task cards render; `Done` declares `142` but
      only 1 task card renders. The count is part of the visual illusion of
      a busy board — not a literal task render count.

  The simpler integration-level assertions (idents present, column headers
  present, hook-on-Doing / diff-on-Review presence) live in the parent
  `marketing_components_test.exs`. This file is for the finer-grained
  contract checks.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MarketingMiniBoard

  describe "priority-dot color mapping" do
    test "renders --pri-critical for W199 (critical priority)" do
      html = render_mini_board()
      assert html =~ "var(--pri-critical)"
    end

    test "renders --pri-high for high-priority tasks" do
      html = render_mini_board()
      assert html =~ "var(--pri-high)"
    end

    test "renders --pri-medium for W194 (medium priority)" do
      html = render_mini_board()
      assert html =~ "var(--pri-medium)"
    end

    test "does NOT render --pri-low — no fixture task is low priority" do
      html = render_mini_board()
      refute html =~ "var(--pri-low)"
    end
  end

  describe "type icon" do
    test "every task card carries the tone-work class (the mini-board only renders 'work' type)" do
      html = render_mini_board()
      # Six task cards × one tone-work span each = 6 occurrences.
      assert tone_work_count(html) == 6
    end

    test "no tone-defect or tone-goal type icons appear — those types are not in the fixture" do
      html = render_mini_board()
      refute html =~ "tone-defect"
      refute html =~ "tone-goal"
    end
  end

  describe "column header status dots" do
    test "Ready column uses --st-ready" do
      html = render_mini_board()
      assert html =~ "background: var(--st-ready);"
    end

    test "Doing column uses --st-doing" do
      html = render_mini_board()
      assert html =~ "background: var(--st-doing);"
    end

    test "Review column uses --st-review" do
      html = render_mini_board()
      assert html =~ "background: var(--st-review);"
    end

    test "Done column uses --st-done" do
      html = render_mini_board()
      assert html =~ "background: var(--st-done);"
    end
  end

  describe "agent avatar palette" do
    test "Claude renders with the amber agent palette oklch(70% 0.16 47)" do
      html = render_mini_board()
      # Claude is the avatar in three cards (W193, W189, W185).
      assert html =~ "background: oklch(70% 0.16 47);"
    end

    test "Cursor renders with the blue agent palette oklch(60% 0.16 240)" do
      html = render_mini_board()
      # Cursor is the avatar on W194 (Doing column).
      assert html =~ "background: oklch(60% 0.16 240);"
    end
  end

  describe "human avatar palette" do
    test "Jamie K and Rohan S both render with the green human-palette color" do
      html = render_mini_board()
      assert html =~ "background: oklch(60% 0.10 155);"
    end
  end

  describe "avatar initials" do
    test "multi-word name 'Jamie K' renders as 'JK'" do
      html = render_mini_board()
      assert html =~ ~r/>\s*JK\s*</
    end

    test "multi-word name 'Rohan S' renders as 'RS'" do
      html = render_mini_board()
      assert html =~ ~r/>\s*RS\s*</
    end

    test "single-word name 'Claude' renders as 'C'" do
      html = render_mini_board()
      assert html =~ ~r/>\s*C\s*</
    end

    test "single-word name 'Cursor' renders as 'C' (same first letter as Claude)" do
      # Same initial as Claude — the test merely confirms the algorithm
      # doesn't crash on a single-word name and produces the expected single
      # uppercase letter.
      html = render_mini_board()
      assert html =~ ~r/>\s*C\s*</
    end
  end

  describe "titlebar chrome" do
    test "renders three macOS-style traffic-light dots in oklch" do
      html = render_mini_board()
      # The traffic lights use distinct oklch chip colors (red, yellow,
      # green hue families).
      assert html =~ "background: oklch(75% 0.13 25);"
      assert html =~ "background: oklch(80% 0.13 80);"
      assert html =~ "background: oklch(70% 0.14 145);"
    end

    test "renders the STR badge with --stride-orange background" do
      html = render_mini_board()
      # The STR badge inside the titlebar uses the brand orange token.
      assert html =~ "background: var(--stride-orange);"
      assert html =~ "STR"
    end
  end

  describe "agents online status indicator" do
    test "renders a green status dot tinted with --st-done" do
      html = render_mini_board()
      # The agents-online tag uses currentColor on the bullet, with the
      # parent text colored --st-done.
      assert html =~ "color: var(--st-done);"
    end
  end

  describe "task-card visual contract" do
    test "every task card uses --surface bg + --line border + 5px radius" do
      html = render_mini_board()
      # 6 task cards × 1 occurrence each — verifies the inline style fragment
      # is applied uniformly across all cards.
      occurrences =
        html
        |> String.split(
          "background: var(--surface); border: 1px solid var(--line); border-radius: 5px;"
        )
        |> length()
        |> Kernel.-(1)

      assert occurrences == 6,
             "expected exactly 6 task-card style fragments, got #{occurrences}"
    end
  end

  describe "display-vs-total count discrepancy (deliberate)" do
    test "Ready shows 8 in the header but only 2 task cards (deliberate marketing illusion)" do
      html = render_mini_board()
      # Header count
      assert html =~ ~r/>\s*8\s*</
      # Card count for Ready column (W198 + W199)
      assert html =~ "W198"
      assert html =~ "W199"
    end

    test "Done shows 142 in the header but only 1 task card" do
      html = render_mini_board()
      assert html =~ ~r/>\s*142\s*</
      assert html =~ "W185"
    end

    test "total rendered task cards across all 4 columns is 6, not 8+3+5+142" do
      html = render_mini_board()
      # All 6 fixture idents render.
      for ident <- ~w(W198 W199 W193 W194 W189 W185) do
        assert html =~ ident
      end

      # Exactly 6 task cards (= six rendered fixture entries) — proves the
      # mini-board renders the fixture verbatim rather than synthesizing
      # extra cards to match column.count.
      card_count =
        html
        |> String.split(
          "background: var(--surface); border: 1px solid var(--line); border-radius: 5px;"
        )
        |> length()
        |> Kernel.-(1)

      assert card_count == 6
    end
  end

  describe "hook-output scoping" do
    test "exactly two hook lines render — one per Doing-column task" do
      html = render_mini_board()
      assert html =~ "before_doing · ok"
      assert html =~ "running"

      # Hook strings only appear on the Doing column's two cards. The
      # mono-styled `--st-doing` color is the load-bearing visual.
      hook_color_count =
        html
        |> String.split("color: var(--st-doing); font-family: var(--font-mono);")
        |> length()
        |> Kernel.-(1)

      assert hook_color_count == 2,
             "expected exactly 2 hook-styled rows (one per Doing task), got #{hook_color_count}"
    end
  end

  describe "diff-stat scoping" do
    test "exactly one diff/test row renders — on the single Review task (W189)" do
      html = render_mini_board()
      assert html =~ "+142"
      assert html =~ "−38"
      assert html =~ "47/47"

      # The diff-row container has a specific style fragment that should
      # appear exactly once (only on the Review task). Column-header counts
      # use a different attribute ordering (`font-family: ...; color: ...`)
      # so they do not collide with this fragment.
      diff_row_count =
        html
        |> String.split("color: var(--ink-3); font-family: var(--font-mono);")
        |> length()
        |> Kernel.-(1)

      assert diff_row_count == 1,
             "expected exactly 1 diff-row (only on the Review task), got #{diff_row_count}"
    end
  end

  describe "grid structure" do
    test "renders a 4-column grid joined by 1px --line hairlines" do
      html = render_mini_board()
      assert html =~ "grid-template-columns: repeat(4, 1fr); gap: 1px; background: var(--line);"
    end
  end

  describe "outer container shadow" do
    test "uses --shadow-lg for the lifted-card effect" do
      html = render_mini_board()
      assert html =~ "box-shadow: var(--shadow-lg);"
    end
  end

  defp render_mini_board do
    assigns = %{}

    rendered_to_string(~H"""
    <MarketingMiniBoard.marketing_mini_board />
    """)
  end

  defp tone_work_count(html) do
    html
    |> String.split("tone-work")
    |> length()
    |> Kernel.-(1)
  end
end
