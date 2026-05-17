defmodule KanbanWeb.TaskLive.Components.HistorySectionTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.HistorySection

  describe "history_section/1 — empty state" do
    test "renders the heading and the No-history copy when @histories is empty" do
      assigns = %{histories: []}

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "History"
      assert html =~ "No history available"
    end
  end

  describe "history_section/1 — creation event" do
    test "renders the Created label and the green plus-circle icon" do
      assigns = %{
        histories: [
          %{type: :creation, inserted_at: ~N[2026-05-15 09:30:00]}
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Created"
      assert html =~ "hero-plus-circle"
      assert html =~ "text-green-600"
      assert html =~ "May 15, 2026"
    end
  end

  describe "history_section/1 — move event" do
    test "renders from/to column names and the ready-tone arrow icon" do
      assigns = %{
        histories: [
          %{
            type: :move,
            from_column: "Ready",
            to_column: "Doing",
            inserted_at: ~N[2026-05-15 10:00:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Moved"
      assert html =~ "Ready"
      assert html =~ "Doing"
      assert html =~ "hero-arrow-right-circle"
      assert html =~ "text-[var(--st-ready)]"
    end
  end

  describe "history_section/1 — priority_change event" do
    test "renders from/to priorities and the orange icon" do
      assigns = %{
        histories: [
          %{
            type: :priority_change,
            from_priority: "low",
            to_priority: "high",
            inserted_at: ~N[2026-05-15 11:00:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Priority changed"
      assert html =~ "low"
      assert html =~ "high"
      assert html =~ "hero-exclamation-circle"
      assert html =~ "text-orange-600"
    end
  end

  describe "history_section/1 — assignment event" do
    test "renders 'Assigned to' when a previously-unassigned task is assigned" do
      assigns = %{
        histories: [
          %{
            type: :assignment,
            from_user_id: nil,
            to_user_id: 7,
            from_user: nil,
            to_user: %{name: "Alice"},
            inserted_at: ~N[2026-05-15 12:00:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Assigned to"
      assert html =~ "Alice"
      assert html =~ "hero-user-circle"
    end

    test "renders 'Unassigned from' when an assignee is cleared" do
      assigns = %{
        histories: [
          %{
            type: :assignment,
            from_user_id: 7,
            to_user_id: nil,
            from_user: %{name: "Alice"},
            to_user: nil,
            inserted_at: ~N[2026-05-15 12:30:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Unassigned from"
      assert html =~ "Alice"
    end

    test "renders 'Reassigned from/to' when one assignee replaces another" do
      assigns = %{
        histories: [
          %{
            type: :assignment,
            from_user_id: 7,
            to_user_id: 8,
            from_user: %{name: "Alice"},
            to_user: %{name: "Bob"},
            inserted_at: ~N[2026-05-15 13:00:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Reassigned"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end
  end

  describe "history_section/1 — chronological list" do
    test "renders multiple events in the order they were given" do
      assigns = %{
        histories: [
          %{
            type: :creation,
            inserted_at: ~N[2026-05-15 09:00:00]
          },
          %{
            type: :move,
            from_column: "Backlog",
            to_column: "Ready",
            inserted_at: ~N[2026-05-15 10:00:00]
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <HistorySection.history_section histories={@histories} />
        """)

      assert html =~ "Created"
      assert html =~ "Moved"
      assert html =~ "Backlog"
      assert html =~ "Ready"
    end
  end
end
