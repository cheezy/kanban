defmodule KanbanWeb.BoardPulseCardTest do
  @moduledoc """
  Contract tests for `KanbanWeb.BoardPulseCard.board_pulse_card/1` —
  the single-board card used by the Boards index.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.BoardPulseCard

  defp build_board(overrides \\ %{}) do
    base = %{
      id: 1,
      name: "Stride core",
      description: "The Stride codebase itself.",
      ai_optimized_board: true,
      accent: :orange,
      metrics: %{
        open: 87,
        doing: 4,
        review: 5,
        done: 142,
        throughput_14d: 84,
        pulse_14d: [3, 4, 6, 5, 7, 8, 9, 6, 7, 8, 5, 6, 7, 9],
        active_agents_14d: 3,
        last_activity_at: DateTime.add(DateTime.utc_now(), -120, :second)
      }
    }

    Map.merge(base, overrides)
  end

  describe "board_pulse_card/1 — identifier + name + description" do
    test "renders the 3-letter identifier prefix derived from the name" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # "Stride core" → "STR" (consonants/letters dropped through, first 3)
      assert html =~ ~r/>\s*STR\s*</
    end

    test "renders the board name in the heading" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "Stride core"
    end

    test "renders the description when present" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "The Stride codebase itself."
    end

    test "omits the description paragraph when the board has no description" do
      assigns = %{board: build_board(%{description: nil})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      refute html =~ ~r/<p[\s>]/
    end

    test "omits the description paragraph when the description is blank" do
      assigns = %{board: build_board(%{description: "   "})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      refute html =~ ~r/<p[\s>]/
    end

    test "pads the identifier prefix to 3 characters for short names" do
      assigns = %{board: build_board(%{name: "QA"})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~r/>\s*QA\?\s*</
    end
  end

  describe "board_pulse_card/1 — AI Pill" do
    test "renders the AI pill when ai_optimized_board is true" do
      assigns = %{board: build_board(%{ai_optimized_board: true})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~r/>\s*AI\s*</
      assert html =~ "var(--stride-violet-soft)"
    end

    test "does NOT render the AI pill when ai_optimized_board is false" do
      assigns = %{board: build_board(%{ai_optimized_board: false})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      refute html =~ ~r/>\s*AI\s*</
    end

    test "does NOT render the AI pill when ai_optimized_board is missing" do
      board = build_board() |> Map.delete(:ai_optimized_board)
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      refute html =~ ~r/>\s*AI\s*</
    end
  end

  describe "board_pulse_card/1 — accent color" do
    test "uses var(--stride-orange) for accent :orange (identifier badge + sparkline stroke)" do
      assigns = %{board: build_board(%{accent: :orange})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # Identifier badge background
      assert html =~ "background: var(--stride-orange);"
      # Sparkline stroke
      assert html =~ ~s[stroke="var(--stride-orange)"]
    end

    test "maps each accent atom to its CSS variable" do
      for {accent, css_var} <- [
            {:ready, "var(--st-ready)"},
            {:doing, "var(--st-doing)"},
            {:violet, "var(--stride-violet)"},
            {:backlog, "var(--st-backlog)"},
            {:blocked, "var(--st-blocked)"}
          ] do
        assigns = %{board: build_board(%{accent: accent})}

        html =
          rendered_to_string(~H"""
          <BoardPulseCard.board_pulse_card board={@board} />
          """)

        assert html =~ "background: #{css_var};",
               "expected #{css_var} for accent #{inspect(accent)}"

        assert html =~ ~s[stroke="#{css_var}"]
      end
    end

    test "falls back to var(--ink-3) when accent is missing or unknown" do
      board = build_board() |> Map.delete(:accent)
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "background: var(--ink-3);"
    end
  end

  describe "board_pulse_card/1 — pulse row" do
    test "displays the throughput_14d value" do
      assigns = %{board: build_board(%{metrics: %{build_board().metrics | throughput_14d: 42}})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~r/>\s*42\s*</
    end

    test "passes pulse_14d data into the sparkline" do
      # A board with all-zeros pulse → sparkline polyline points all at y=21.
      flat = List.duplicate(0, 14)
      board = build_board(%{metrics: %{build_board().metrics | pulse_14d: flat}})
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # 14 points, all at y = 21 (default height 22)
      assert html =~ ~s[points="0,21]
      # Last point at x = 88 (default width)
      assert html =~ "88,21\""
    end
  end

  describe "board_pulse_card/1 — 4-stat row" do
    test "renders each stat label" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~r/>\s*To Do\s*</
      assert html =~ ~r/>\s*Doing\s*</
      assert html =~ ~r/>\s*Review\s*</
      assert html =~ ~r/>\s*Done\s*</
    end

    test "renders each stat value from the metrics map" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~r/>\s*87\s*</
      assert html =~ ~r/>\s*4\s*</
      assert html =~ ~r/>\s*5\s*</
      assert html =~ ~r/>\s*142\s*</
    end

    test "applies the right color token to each stat value" do
      assigns = %{board: build_board()}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "color: var(--ink);"
      assert html =~ "color: var(--st-doing);"
      assert html =~ "color: var(--st-review);"
      assert html =~ "color: var(--st-done);"
    end
  end

  describe "board_pulse_card/1 — member stack" do
    test "renders an explicit members list when the board provides one" do
      members = [
        %{kind: :agent, name: "Claude", palette: "agent-claude"},
        %{kind: :human, name: "Jamie K", palette: "human-green"}
      ]

      board = build_board(%{members: members})
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # Agent claude amber + human green palettes both render.
      assert html =~ "background: oklch(70% 0.16 47);"
      assert html =~ "background: oklch(60% 0.10 155);"
    end

    test "synthesizes members from active_agents_14d count when no list is provided" do
      board = build_board(%{metrics: %{build_board().metrics | active_agents_14d: 2}})
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # 2 synthetic agents → claude amber and cursor blue.
      assert html =~ "background: oklch(70% 0.16 47);"
      assert html =~ "background: oklch(60% 0.16 240);"
    end

    test "renders an empty stack when active_agents_14d is zero and no members provided" do
      board = build_board(%{metrics: %{build_board().metrics | active_agents_14d: 0}})
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      # No avatar markup expected in the footer when there are zero contributors.
      refute html =~ "border-radius: 4px;"
    end
  end

  describe "board_pulse_card/1 — last activity footer" do
    test "renders relative time for a recent timestamp" do
      board =
        build_board(%{
          metrics: %{
            build_board().metrics
            | last_activity_at: DateTime.add(DateTime.utc_now(), -120, :second)
          }
        })

      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "2m ago"
    end

    test "renders hours for a timestamp a few hours back" do
      board =
        build_board(%{
          metrics: %{
            build_board().metrics
            | last_activity_at: DateTime.add(DateTime.utc_now(), -4 * 3600, :second)
          }
        })

      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "4h ago"
    end

    test "renders days for a timestamp several days back" do
      board =
        build_board(%{
          metrics: %{
            build_board().metrics
            | last_activity_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
          }
        })

      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "3d ago"
    end

    test "renders an em-dash when last_activity_at is nil (no crash)" do
      board = build_board(%{metrics: %{build_board().metrics | last_activity_at: nil}})
      assigns = %{board: board}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ "—"
      refute html =~ "ago"
    end
  end

  describe "board_pulse_card/1 — accessibility" do
    test "wraps the card body in a verified-route link to the board" do
      assigns = %{board: build_board(%{id: 42})}

      html =
        rendered_to_string(~H"""
        <BoardPulseCard.board_pulse_card board={@board} />
        """)

      assert html =~ ~s[href="/boards/42"]
    end
  end
end
