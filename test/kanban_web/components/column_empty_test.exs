defmodule KanbanWeb.ColumnEmptyTest do
  @moduledoc """
  Contract tests for `KanbanWeb.ColumnEmpty.column_empty/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ColumnEmpty

  describe "column_empty/1 — dashed placeholder card" do
    test "renders the dashed border card and the plus icon" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ColumnEmpty.column_empty />
        """)

      assert html =~ "1.5px dashed var(--line-strong)"
      assert html =~ "hero-plus"
    end

    test "marks the container with data-column-empty" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ColumnEmpty.column_empty />
        """)

      assert html =~ "data-column-empty"
    end
  end

  describe "column_empty/1 — status-specific hint" do
    for {status, snippet} <- [
          {:backlog, "Unrefined ideas"},
          {:ready, "Agents pull from this column"},
          {:doing, "In-flight work"},
          {:review, "Humans review here"},
          {:done, "Shipped."}
        ] do
      test "#{status} → renders the matching hint" do
        assigns = %{status: unquote(status)}

        html =
          rendered_to_string(~H"""
          <ColumnEmpty.column_empty status={@status} />
          """)

        assert html =~ unquote(snippet)
      end
    end

    test "unknown status falls back to the default 'Drop a task here.' copy" do
      assigns = %{status: :unknown}

      html =
        rendered_to_string(~H"""
        <ColumnEmpty.column_empty status={@status} />
        """)

      assert html =~ "Drop a task here."
    end

    test "default status (no attr passed) is :backlog" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ColumnEmpty.column_empty />
        """)

      assert html =~ "Unrefined ideas"
    end
  end
end
