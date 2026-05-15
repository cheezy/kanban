defmodule KanbanWeb.BoardTabsTest do
  @moduledoc """
  Contract tests for `KanbanWeb.BoardTabs.board_tabs/1` — the
  horizontal tab row under the board name header.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.BoardTabs

  defp board(overrides \\ %{}) do
    Map.merge(%{id: 42}, overrides)
  end

  describe "board_tabs/1 — tab labels" do
    test "renders all five non-owner tabs" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} />
        """)

      for label <- ~w(Board List Goals Archive Members) do
        assert html =~ ~r/>\s*#{label}\s*</,
               "expected tab label #{label} to render"
      end
    end

    test "owner? sees Tokens and Settings tabs" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} owner? />
        """)

      assert html =~ ~r/>\s*Tokens\s*</
      assert html =~ ~r/>\s*Settings\s*</
    end

    test "non-owner does NOT see Tokens or Settings" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} />
        """)

      refute html =~ ~r/>\s*Tokens\s*</
      refute html =~ ~r/>\s*Settings\s*</
    end
  end

  describe "board_tabs/1 — active underline" do
    test "active tab has --stride-orange underline + bold + colored icon" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} active={:board} />
        """)

      assert html =~ "border-bottom: 2px solid var(--stride-orange);"
      assert html =~ "color: var(--ink);"
      assert html =~ "font-weight: 600"
      assert html =~ "color: var(--stride-orange); display: inline-flex;"
    end

    test "inactive tabs use transparent underline + --ink-3 text + --ink-4 icon" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} active={:board} />
        """)

      # Inactive tabs still appear; check their styling shows up at least once
      assert html =~ "border-bottom: 2px solid transparent;"
      assert html =~ "color: var(--ink-3);"
      assert html =~ "color: var(--ink-4)"
    end

    test "unknown :active atom renders no active underline" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} active={:nonexistent} />
        """)

      refute html =~ "border-bottom: 2px solid var(--stride-orange);"
    end

    test "marks the active tab with aria-current=page" do
      assigns = %{board: board()}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} active={:archive} />
        """)

      assert html =~ ~s(aria-current="page")
    end
  end

  describe "board_tabs/1 — link targets" do
    test "real routes resolve to their existing paths" do
      assigns = %{board: board(%{id: 42})}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} owner? />
        """)

      assert html =~ ~s(href="/boards/42/archive")
      assert html =~ ~s(href="/boards/42/api_tokens")
    end

    test "placeholder tabs (List, Goals, Members, Settings) point to the board show page" do
      assigns = %{board: board(%{id: 42})}

      html =
        rendered_to_string(~H"""
        <BoardTabs.board_tabs board={@board} owner? />
        """)

      # Multiple tabs link to /boards/42 (Board, List, Goals, Members, Settings).
      # Just verify the href is present at least once.
      assert html =~ ~s(href="/boards/42")
    end
  end
end
