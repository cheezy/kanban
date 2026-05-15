defmodule KanbanWeb.ColumnHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.ColumnHeader.column_header/1` — the
  status-colored kanban column header strip.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ColumnHeader

  defp column(overrides \\ %{}) do
    Map.merge(%{id: 1, name: "Backlog", wip_limit: 0}, overrides)
  end

  describe "column_header/1 — status dot color" do
    for {name, css_var} <- [
          {"Backlog", "var(--st-backlog)"},
          {"Ready", "var(--st-ready)"},
          {"Doing", "var(--st-doing)"},
          {"Review", "var(--st-review)"},
          {"Done", "var(--st-done)"}
        ] do
      test "#{name} → #{css_var}" do
        assigns = %{column: column(%{name: unquote(name)})}

        html =
          rendered_to_string(~H"""
          <ColumnHeader.column_header column={@column} count={3} />
          """)

        assert html =~ "background: #{unquote(css_var)};"
      end
    end

    test "matches case-insensitively (lowercase names render same color)" do
      assigns = %{column: column(%{name: "review"})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={1} />
        """)

      assert html =~ "background: var(--st-review);"
    end

    test "unknown column name falls back to var(--ink-4)" do
      assigns = %{column: column(%{name: "Triage"})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={0} />
        """)

      assert html =~ "background: var(--ink-4);"
    end
  end

  describe "column_header/1 — count and WIP badge" do
    test "renders just the count when wip_limit is 0" do
      assigns = %{column: column(%{wip_limit: 0})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={4} />
        """)

      assert html =~ ~r/>\s*4\s*</
      refute html =~ "/0"
    end

    test "renders count/wip when wip_limit is set" do
      assigns = %{column: column(%{wip_limit: 5})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={3} />
        """)

      assert html =~ ~r/>\s*3\/5\s*</
    end

    test "handles count = 0 without a WIP limit" do
      assigns = %{column: column()}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={0} />
        """)

      assert html =~ ~r/>\s*0\s*</
    end

    test "count equal to wip_limit is NOT over-wip" do
      assigns = %{column: column(%{wip_limit: 3})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={3} />
        """)

      # Badge keeps neutral colors when count == wip
      assert html =~ "color: var(--ink-3);"
      refute html =~ "color: var(--st-blocked);"
    end
  end

  describe "column_header/1 — over-WIP highlight" do
    test "applies --st-blocked-soft ring and badge bg when count > wip" do
      assigns = %{column: column(%{wip_limit: 2})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={4} />
        """)

      # Ring around the status dot
      assert html =~ "box-shadow: 0 0 0 3px var(--st-blocked-soft);"
      # Badge background flips to blocked-soft
      assert html =~ "background: var(--st-blocked-soft);"
      # Badge text flips to blocked
      assert html =~ "color: var(--st-blocked);"
    end

    test "ring is transparent when not over WIP" do
      assigns = %{column: column(%{wip_limit: 5})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={2} />
        """)

      assert html =~ "box-shadow: 0 0 0 3px transparent;"
    end
  end

  describe "column_header/1 — +task button" do
    test "renders the + task link with the provided patch target" do
      assigns = %{column: column()}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header
          column={@column}
          count={0}
          new_task_path="/boards/42/columns/1/tasks/new"
        />
        """)

      assert html =~ ~s(href="/boards/42/columns/1/tasks/new")
      assert html =~ ~s(aria-label="Add Task")
      assert html =~ ~s(data-tip="Add Task")
      assert html =~ "hero-plus"
    end

    test "omits the + task link when new_task_path is nil (read-only viewers)" do
      assigns = %{column: column()}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={0} />
        """)

      refute html =~ ~s(aria-label="Add task")
      refute html =~ "hero-plus"
    end
  end

  describe "column_header/1 — wip_limit fallbacks" do
    test "treats nil wip_limit as 0 (count only, no over-wip)" do
      assigns = %{column: column(%{wip_limit: nil})}

      html =
        rendered_to_string(~H"""
        <ColumnHeader.column_header column={@column} count={7} />
        """)

      assert html =~ ~r/>\s*7\s*</
      refute html =~ "var(--st-blocked-soft)"
    end
  end
end
