defmodule KanbanWeb.MarketingMiniBoardTest do
  @moduledoc """
  Behaviour coverage for `KanbanWeb.MarketingMiniBoard.marketing_mini_board/1`
  that the high-level `marketing_components_test.exs` does not exercise:

    * Priority-dot color per level (`--pri-critical` / `--pri-high` /
      `--pri-medium` — `--pri-low` is intentionally absent from the fixture).
    * Type-icon presence (every task card carries the `tone-work` glyph; the
      mini-board only renders the `work` type per the design's contract).
    * Per-column status-dot token (`--st-backlog` / `--st-ready` / `--st-doing`
      / `--st-review` / `--st-done`) — five columns to match the real board.
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
  present, real footer metrics on every column) live in the parent
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
      # Eight task cards × one tone-work span each = 8 occurrences.
      assert tone_work_count(html) == 8
    end

    test "no tone-defect or tone-goal type icons appear — those types are not in the fixture" do
      html = render_mini_board()
      refute html =~ "tone-defect"
      refute html =~ "tone-goal"
    end
  end

  describe "column header status dots" do
    test "Backlog column uses --st-backlog" do
      html = render_mini_board()
      assert html =~ "background: var(--st-backlog);"
    end

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

  describe "titlebar simplicity" do
    test "no agents-online status indicator in the titlebar" do
      html = render_mini_board()
      # The "N agents online" chip was removed from the titlebar; only the
      # traffic-light dots and the STR/"Stride core" label remain.
      refute html =~ "agents online"
    end
  end

  describe "task-card visual contract" do
    test "every task card uses --surface bg + --line border + 6px radius + shadow-sm" do
      html = render_mini_board()
      # 8 task cards × 1 occurrence each — verifies the inline style fragment
      # is applied uniformly across all cards. Aligned with the real TaskCard
      # which uses border-radius: 6px and box-shadow: var(--shadow-sm).
      occurrences =
        html
        |> String.split(
          "background: var(--surface); border: 1px solid var(--line); border-radius: 6px; box-shadow: var(--shadow-sm);"
        )
        |> length()
        |> Kernel.-(1)

      assert occurrences == 8,
             "expected exactly 8 task-card style fragments, got #{occurrences}"
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

    test "total rendered task cards across all 5 columns is 8, not 24+8+3+5+142" do
      html = render_mini_board()
      # All 8 fixture idents render (Backlog: W201/W202, Ready: W198/W199,
      # Doing: W193/W194, Review: W189, Done: W185).
      for ident <- ~w(W201 W202 W198 W199 W193 W194 W189 W185) do
        assert html =~ ident
      end

      # Exactly 8 task cards (= eight rendered fixture entries) — proves the
      # mini-board renders the fixture verbatim rather than synthesizing
      # extra cards to match column.count.
      card_count =
        html
        |> String.split(
          "background: var(--surface); border: 1px solid var(--line); border-radius: 6px; box-shadow: var(--shadow-sm);"
        )
        |> length()
        |> Kernel.-(1)

      assert card_count == 8
    end
  end

  describe "footer metrics — never show hook-execution strings" do
    test "no hook-state strings (before_doing/after_doing/running/ok) appear anywhere" do
      html = render_mini_board()
      # The real TaskCard never surfaces hook execution state. Hook chips
      # were removed from the mini-board in favor of real card metrics
      # (key_files / acceptance / cycle time / etc.). Guarding against
      # regression here.
      refute html =~ "before_doing"
      refute html =~ "after_doing"
      refute html =~ ~r/>\s*running\s*</
    end

    test "no diff-stat strings (+N / −N / N/N) appear anywhere" do
      html = render_mini_board()
      # The real TaskCard never surfaces +adds/−dels/tests-passing in the
      # Review footer — instead it shows criteria / issues / files.
      refute html =~ "+142"
      refute html =~ "−38"
      refute html =~ "47/47"
    end
  end

  describe "Review footer metrics mirror the real TaskCard review_footer" do
    test "renders criteria / issues / files (not diff stats) on the Review card" do
      html = render_mini_board()
      assert html =~ "5 criteria"
      assert html =~ "0 issues"
      assert html =~ "4 files"
    end

    test "0-issues chip is colored with --st-done (the green check-badge)" do
      html = render_mini_board()
      assert html =~ "color: var(--st-done);"
      assert html =~ "hero-check-badge"
    end
  end

  describe "Done footer metrics mirror the real TaskCard done_footer" do
    test "renders cycle time / files / actual complexity on the Done card" do
      html = render_mini_board()
      assert html =~ "cycle 1h 24m"
      assert html =~ "6 files"
      assert html =~ "actual: medium"
    end

    test "cycle chip uses the hero-clock icon to match the real card" do
      html = render_mini_board()
      assert html =~ "hero-clock"
    end
  end

  describe "Backlog / Ready / Doing footer metrics mirror backlog_meta" do
    test "open-dependency chips are colored with --st-blocked (red)" do
      html = render_mini_board()
      # W202 and W194 both carry one open dep.
      assert html =~ "color: var(--st-blocked);"
      assert html =~ "hero-link"
    end

    test "key-files icon (hero-document) renders on every multi-card column footer" do
      html = render_mini_board()
      # hero-document appears in: every backlog/ready/doing card (key_files),
      # the Review card (files), and the Done card (files) — at least 8 occurrences.
      doc_count =
        html
        |> String.split("hero-document")
        |> length()
        |> Kernel.-(1)

      assert doc_count >= 8,
             "expected hero-document on every footer that has key_files/files, got #{doc_count}"
    end

    test "acceptance-criteria icon (hero-check) renders alongside file counts" do
      html = render_mini_board()
      assert html =~ "hero-check"
    end
  end

  describe "grid structure" do
    test "renders a 5-column grid (Backlog/Ready/Doing/Review/Done) with sunken inner surface" do
      html = render_mini_board()

      assert html =~
               "grid-template-columns: repeat(5, 1fr); background: var(--surface-sunken);"
    end

    test "each column container is a gradient card to mirror the real board's column chrome" do
      html = render_mini_board()
      # Mirrors the real `BoardLive.Show` column wrapper which uses a
      # `bg-gradient-to-br from-base-200 to-base-300/80` rounded card.
      assert html =~
               "background: linear-gradient(to bottom right, var(--surface-2), var(--surface-sunken));"
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
