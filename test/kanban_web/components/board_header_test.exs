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

  describe "board_header/1 — AI pill" do
    test "renders the AI pill when ai_optimized_board is true" do
      assigns = %{board: board(%{ai_optimized_board: true})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ ~r/>\s*AI\s*</
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"
    end

    test "does NOT render the AI pill when ai_optimized_board is false" do
      assigns = %{board: board(%{ai_optimized_board: false})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ ~r/>\s*AI\s*</
    end

    test "does NOT render the AI pill when ai_optimized_board is missing" do
      assigns = %{board: board() |> Map.delete(:ai_optimized_board)}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      refute html =~ ~r/>\s*AI\s*</
    end
  end

  describe "board_header/1 — status counts" do
    test "renders 'in flight' / 'in review' / 'shipped' labels with the right values" do
      assigns = %{board: board(%{metrics: %{open: 0, doing: 7, review: 3, done: 99}})}

      html =
        rendered_to_string(~H"""
        <BoardHeader.board_header board={@board} />
        """)

      assert html =~ "in flight"
      assert html =~ "in review"
      assert html =~ "shipped"
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

      # Each KV shows 0 for in flight / in review / shipped
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
end
