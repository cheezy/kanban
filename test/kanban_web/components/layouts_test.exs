defmodule KanbanWeb.LayoutsTest do
  @moduledoc """
  Tests for the SideNav rendering in `KanbanWeb.Layouts`.

  Covers the Agents nav entry — both inside a board scope and outside
  one — and the active-state highlight on /agents.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts.Scope
  alias KanbanWeb.Layouts

  defp scope_for(user), do: Scope.for_user(user)

  describe "side_nav/1 — Agents entry" do
    test "renders an Agents link pointing to /agents when outside any board" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: nil, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      assert html =~ "Agents"
      assert html =~ ~s(href="/agents")
    end

    test "renders the Agents link inside a board scope as well" do
      user = user_fixture()
      board = board_fixture(user)
      assigns = %{current_scope: scope_for(user), active: nil, board: board}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      assert html =~ "Agents"
      assert html =~ ~s(href="/agents")
    end

    test "renders the Agents link exactly once when inside a board (no duplicate)" do
      user = user_fixture()
      board = board_fixture(user)
      assigns = %{current_scope: scope_for(user), active: nil, board: board}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      hrefs = Regex.scan(~r/href="\/agents"/, html)
      assert length(hrefs) == 1
    end

    test "active state highlights the Agents entry when :agents is passed" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: :agents, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      # The active entry's row carries the active background token
      # `var(--surface)` and its icon paints with `var(--stride-orange)`.
      # Capture the markup of the row whose `<.link>` points at /agents and
      # assert both signals land there — not anywhere else in the SideNav.
      [_, after_href] = String.split(html, ~s(href="/agents"), parts: 2)
      [row_inner, _] = String.split(after_href, "</a>", parts: 2)

      assert row_inner =~ "var(--surface)"
      assert row_inner =~ "var(--stride-orange)"
      assert row_inner =~ "Agents"
    end

    test "Agents entry uses inactive styling when a different item is active" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: :boards, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      [_, after_href] = String.split(html, ~s(href="/agents"), parts: 2)
      [row_inner, _] = String.split(after_href, "</a>", parts: 2)

      # Inactive row: no surface background, icon paints with var(--ink-4).
      refute row_inner =~ "background: var(--surface);"
      assert row_inner =~ "var(--ink-4)"
    end
  end

  describe "side_nav/1 — Metrics entry (W586)" do
    test "renders a workspace Metrics link pointing to /metrics outside a board" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: nil, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      assert html =~ "Metrics"
      assert html =~ ~s(href="/metrics")
      assert html =~ "hero-chart-bar"
    end

    test "renders the workspace Metrics link exactly once when inside a board scope" do
      # The side_nav :board attr is documented as reserved for future
      # board-aware nav state and is currently unused by the nav itself.
      # The workspace /metrics entry from primary_nav_items/1 appears
      # regardless of board context, and there is no second /metrics
      # link emitted by the SideNav even inside a board.
      user = user_fixture()
      board = board_fixture(user)
      assigns = %{current_scope: scope_for(user), active: nil, board: board}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      hrefs = Regex.scan(~r/href="\/metrics"/, html)
      assert length(hrefs) == 1
    end

    test "active state highlights the Metrics entry when :metrics is passed" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: :metrics, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      [_, after_href] = String.split(html, ~s(href="/metrics"), parts: 2)
      [row_inner, _] = String.split(after_href, "</a>", parts: 2)

      assert row_inner =~ "var(--surface)"
      assert row_inner =~ "var(--stride-orange)"
      assert row_inner =~ "Metrics"
    end

    test "both the new workspace Metrics entry and the existing Boards entry coexist" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: nil, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      assert html =~ ~s(href="/boards")
      assert html =~ ~s(href="/metrics")
    end
  end
end
