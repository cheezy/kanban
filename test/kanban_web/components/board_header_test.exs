defmodule KanbanWeb.BoardHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.BoardHeader.board_header/1` — the
  board-name + AI pill + status-count subhead.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.BoardHeader

  defp board(overrides \\ %{}) do
    Map.merge(
      %{
        id: 42,
        name: "Stride core",
        description: "The Stride codebase itself.",
        ai_optimized_board: false,
        metrics: %{open: 5, doing: 4, review: 2, done: 142}
      },
      overrides
    )
  end

  describe "board_header/1 — basics" do
    test "renders the board name in an <h1>" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ ~r/<h1[^>]*>\s*Stride core\s*<\/h1>/
    end

    test "renders the description when present" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ "The Stride codebase itself."
    end

    test "omits the description span when description is nil" do
      assigns = %{board: board(%{description: nil})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ "color: var(--ink-3); margin-top: 2px;"
    end

    test "omits the description span when description is blank" do
      assigns = %{board: board(%{description: "   "})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ "color: var(--ink-3); margin-top: 2px;"
    end
  end

  describe "ai_pill/1" do
    test "renders the AI pill markup" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <BoardHeader.ai_pill />
        """)

      assert html =~ ~r/>\s*AI\s*</
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"
    end
  end

  describe "board_header/1 — name area" do
    test "does NOT render the AI pill inside the header (now lives in the breadcrumb)" do
      assigns = %{board: board(%{ai_optimized_board: true})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ ~r/>\s*AI\s*</
    end
  end

  describe "board_header/1 — status counts" do
    test "renders 'Doing' / 'Review' / 'Done' labels with the right values" do
      assigns = %{board: board(%{metrics: %{open: 0, doing: 7, review: 3, done: 99}})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ "Doing"
      assert html =~ ">Review<" or html =~ ">\n    Review\n  <"
      assert html =~ "Done"
      assert html =~ ~r/>\s*7\s*</
      assert html =~ ~r/>\s*3\s*</
      assert html =~ ~r/>\s*99\s*</
    end

    test "applies the right status color token to each KV value" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ "color: var(--st-doing);"
      assert html =~ "color: var(--st-review);"
      assert html =~ "color: var(--st-done);"
    end

    test "renders zero counts when metrics is missing entirely" do
      assigns = %{board: board() |> Map.delete(:metrics)}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      # Each KV shows 0 for Doing / Review / Done
      assert html =~ ~r/>\s*0\s*</
    end

    test "falls back to 0 for each individual metric missing from the map" do
      assigns = %{board: board(%{metrics: %{}})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ ~r/>\s*0\s*</
    end
  end

  describe "identifier_badge/1" do
    test "renders a 3-letter prefix from the first three letters of the name" do
      assigns = %{board: board(%{name: "Stride 2.0"})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} />
        """)

      # Non-letters are stripped, then the first three letters are taken.
      assert html =~ ~r/>\s*STR\s*</
    end

    test "pads the prefix with '?' when the name has fewer than three letters" do
      assigns = %{board: board(%{name: "Z"})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} />
        """)

      assert html =~ ~r/>\s*Z\?\?\s*</
    end

    test "renders '???' when the board has no name" do
      assigns = %{board: board(%{name: nil})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} />
        """)

      assert html =~ ~r/>\s*\?\?\?\s*</
    end

    test "uses the smaller font size when size <= 20" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} size={18} />
        """)

      assert html =~ "font-size: 9px;"
    end

    test "uses the larger font size when size > 20 (default 28)" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} />
        """)

      assert html =~ "font-size: 10.5px;"
    end

    for {accent, css_var} <- [
          {:orange, "var(--stride-orange)"},
          {:ready, "var(--st-ready)"},
          {:doing, "var(--st-doing)"},
          {:violet, "var(--stride-violet)"},
          {:backlog, "var(--st-backlog)"},
          {:blocked, "var(--st-blocked)"}
        ] do
      test "accent :#{accent} renders background #{css_var}" do
        assigns = %{board: board(%{accent: unquote(accent)})}

        html =
          rendered_to_string(~H"""
          <BoardHeader.identifier_badge board={@board} />
          """)

        assert html =~ "background: #{unquote(css_var)};"
      end
    end

    test "unknown accent falls back to var(--ink-3)" do
      assigns = %{board: board(%{accent: :unknown_accent})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.identifier_badge board={@board} />
        """)

      assert html =~ "background: var(--ink-3);"
    end
  end

  describe "board_header/1 — description trimming" do
    test "treats an empty-string description as absent" do
      assigns = %{board: board(%{description: ""})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ "color: var(--ink-3); margin-top: 2px;"
    end

    test "treats a non-string description as absent" do
      assigns = %{board: board(%{description: 12_345})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ "color: var(--ink-3); margin-top: 2px;"
    end
  end

  describe "board_header/1 — member stack" do
    test "renders an avatar stack to the right of the KV stats when members are present" do
      assigns = %{
        board:
          board(%{
            members: [
              %{kind: :human, name: "Jamie K", palette: "human-green"},
              %{kind: :human, name: "Pat S", palette: "human-blue"}
            ]
          })
      }

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ "background: oklch(60% 0.10 155);"
      assert html =~ "background: oklch(60% 0.10 240);"
    end

    test "omits the divider and stack when members is empty or absent" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ "width: 1px; height: 24px;"
      refute html =~ "text-white font-semibold"
    end
  end
end
