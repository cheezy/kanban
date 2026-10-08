defmodule KanbanWeb.BoardFilterBarTest do
  @moduledoc """
  Contract tests for `KanbanWeb.BoardFilterBar.board_filter_bar/1` (W2235).
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Tasks.BoardFilters
  alias KanbanWeb.BoardFilterBar

  defp render_bar(attrs) do
    assigns =
      Map.merge(
        %{filters: %BoardFilters{}, labels: [], members: [], active: false, drag_hint: false},
        attrs
      )

    rendered_to_string(~H"""
    <BoardFilterBar.board_filter_bar
      filters={@filters}
      labels={@labels}
      members={@members}
      active={@active}
      drag_hint={@drag_hint}
    />
    """)
  end

  test "renders the search input and selectors wired to filter_change" do
    html = render_bar(%{})

    assert html =~ ~s(id="board-filter-form")
    assert html =~ ~s(phx-change="filter_change")
    assert html =~ ~s(phx-submit="filter_change")
    assert html =~ ~s(id="board-search")
    assert html =~ ~s(name="q")
    assert html =~ ~s(phx-debounce="300")

    for id <- ~w(board-filter-type board-filter-priority board-filter-assignee) do
      assert html =~ ~s(id="#{id}")
    end
  end

  test "omits the label selector when the board has no labels" do
    refute render_bar(%{}) =~ ~s(id="board-filter-label")

    html = render_bar(%{labels: [%{id: 4, name: "Frontend"}]})
    assert html =~ ~s(id="board-filter-label")
    assert html =~ "Frontend"
  end

  test "lists Unassigned and the board's members as assignees" do
    html = render_bar(%{members: [%{user_id: 9, name: "Ada Lovelace"}]})

    assert html =~ ~s(value="unassigned")
    assert html =~ ~s(value="9")
    assert html =~ "Ada Lovelace"
  end

  test "reflects the current filters as selected values" do
    html =
      render_bar(%{
        filters: %BoardFilters{search: "login", type: :defect, assignee: :unassigned},
        active: true
      })

    assert html =~ ~s(value="login")
    assert html =~ ~s(<option selected value="defect">)
    assert html =~ ~s(<option selected value="unassigned">)
  end

  test "shows Clear only while filters are active" do
    refute render_bar(%{}) =~ ~s(id="board-filter-clear")
    assert render_bar(%{active: true}) =~ ~s(phx-click="clear_filters")
  end

  test "shows the drag hint only when asked" do
    refute render_bar(%{active: true}) =~ ~s(id="board-filter-drag-hint")
    assert render_bar(%{active: true, drag_hint: true}) =~ "Drag reordering is off"
  end
end
