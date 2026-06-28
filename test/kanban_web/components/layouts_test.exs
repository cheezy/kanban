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

  describe "side_nav/1 — mobile drawer markup" do
    test "sidebar renders with the drawer-ready id and responsive classes" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), active: nil, board: nil}

      html =
        rendered_to_string(~H"""
        <Layouts.side_nav current_scope={@current_scope} active={@active} board={@board} />
        """)

      # The sidebar must carry id="app-sidebar" so the JS Sidebar hook can target it.
      assert html =~ ~s(id="app-sidebar")

      # Mobile drawer: fixed positioning + off-canvas translate by default.
      assert html =~ "fixed"
      assert html =~ "-translate-x-full"
      assert html =~ "transition-transform"

      # Desktop reset: md:static + md:translate-x-0 restores the inline 160px sidebar.
      assert html =~ "md:static"
      assert html =~ "md:translate-x-0"
      assert html =~ "md:w-[160px]"
    end
  end

  describe "app/1 — mobile drawer backdrop" do
    test "renders the backdrop element for backdrop-close when signed in" do
      user = user_fixture()
      assigns = %{current_scope: scope_for(user), flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app current_scope={@current_scope} flash={@flash}>
          <span>content</span>
        </Layouts.app>
        """)

      # The backdrop the JS Sidebar hook reveals when the drawer is open; a
      # click on it closes the drawer.
      assert html =~ "data-sidebar-backdrop"
      # Hidden by default (and on desktop) and a dim overlay when shown.
      assert html =~ "bg-black/40"
      assert html =~ ~s(aria-hidden="true")
    end

    test "omits the sidebar and backdrop when signed out" do
      assigns = %{current_scope: nil, flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app current_scope={@current_scope} flash={@flash}>
          <span>content</span>
        </Layouts.app>
        """)

      refute html =~ "data-sidebar-backdrop"
      refute html =~ ~s(id="app-sidebar")
    end
  end

  describe "win_top/1 — sidebar toggle" do
    test "renders the hamburger toggle when show_sidebar_toggle is true" do
      assigns = %{show_sidebar_toggle: true}

      html =
        rendered_to_string(~H"""
        <Layouts.win_top show_sidebar_toggle={@show_sidebar_toggle} />
        """)

      assert html =~ "data-sidebar-toggle"
      assert html =~ ~s(aria-controls="app-sidebar")
      assert html =~ ~s(aria-expanded="false")
      assert html =~ "md:hidden"
      # 44x44 tap target
      assert html =~ "w-11 h-11"
    end

    test "omits the hamburger toggle when show_sidebar_toggle is false" do
      assigns = %{show_sidebar_toggle: false}

      html =
        rendered_to_string(~H"""
        <Layouts.win_top show_sidebar_toggle={@show_sidebar_toggle} />
        """)

      refute html =~ "data-sidebar-toggle"
    end
  end
end
