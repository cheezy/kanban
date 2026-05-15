defmodule KanbanWeb.TaskActivityLogTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TaskActivityLog.activity_log/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskActivityLog

  defp entry(overrides) do
    Map.merge(
      %{
        type: :creation,
        from_column: nil,
        to_column: nil,
        from_priority: nil,
        to_priority: nil,
        from_user_id: nil,
        to_user_id: nil,
        from_user: nil,
        to_user: nil,
        inserted_at: ~N[2026-05-11 14:32:00]
      },
      overrides
    )
  end

  describe "activity_log/1 — empty state" do
    test "renders the empty-state message when histories is []" do
      assigns = %{histories: []}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "data-activity-log"
      assert html =~ "No history available"
      refute html =~ "<li"
    end
  end

  describe "activity_log/1 — entry rendering by type" do
    test "renders :creation with the create icon and 'Created' copy" do
      assigns = %{histories: [entry(%{type: :creation})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "hero-plus-circle"
      assert html =~ "Created"
      assert html =~ "var(--st-done)"
    end

    test "renders :move with column transition" do
      assigns = %{
        histories: [
          entry(%{type: :move, from_column: "Backlog", to_column: "Ready"})
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "hero-arrow-right-circle"
      assert html =~ "Moved"
      assert html =~ "Backlog"
      assert html =~ "Ready"
    end

    test "renders :priority_change with priority transition" do
      assigns = %{
        histories: [
          entry(%{type: :priority_change, from_priority: "low", to_priority: "high"})
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "hero-exclamation-circle"
      assert html =~ "Priority changed"
      assert html =~ ">low<"
      assert html =~ ">high<"
    end

    test "renders :assignment assigned-to variant when from_user_id is nil" do
      assigns = %{
        histories: [
          entry(%{
            type: :assignment,
            from_user_id: nil,
            to_user_id: 42,
            to_user: %{name: "Jamie K"}
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "hero-user-circle"
      assert html =~ "Assigned to"
      assert html =~ "Jamie K"
    end

    test "renders :assignment unassigned-from variant when to_user_id is nil" do
      assigns = %{
        histories: [
          entry(%{
            type: :assignment,
            from_user_id: 42,
            to_user_id: nil,
            from_user: %{name: "Jamie K"}
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "Unassigned from"
      assert html =~ "Jamie K"
    end

    test "renders :assignment reassigned variant when both user_ids are non-nil" do
      assigns = %{
        histories: [
          entry(%{
            type: :assignment,
            from_user_id: 42,
            to_user_id: 99,
            from_user: %{name: "Alice"},
            to_user: %{name: "Bob"}
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "Reassigned"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end
  end

  describe "activity_log/1 — ordering" do
    test "renders entries in the order they are given (reverse chronological)" do
      newer =
        entry(%{
          type: :move,
          from_column: "Ready",
          to_column: "Doing",
          inserted_at: ~N[2026-05-12 09:00:00]
        })

      older = entry(%{type: :creation, inserted_at: ~N[2026-05-11 09:00:00]})

      assigns = %{histories: [newer, older]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      newer_idx = :binary.match(html, "Moved") |> elem(0)
      older_idx = :binary.match(html, "Created") |> elem(0)

      assert newer_idx < older_idx
    end
  end

  describe "activity_log/1 — timestamps" do
    test "formats DateTime values" do
      assigns = %{histories: [entry(%{inserted_at: ~U[2026-05-11 14:32:00Z]})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "May 11, 2026"
    end

    test "formats NaiveDateTime values" do
      assigns = %{histories: [entry(%{inserted_at: ~N[2026-05-11 14:32:00]})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "May 11, 2026"
    end
  end

  describe "activity_log/1 — malformed entries" do
    test "renders a fallback for an unknown history type without crashing" do
      assigns = %{histories: [entry(%{type: :totally_unknown})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "Unknown history entry"
      assert html =~ "hero-question-mark-circle"
    end

    test "renders 'Unknown' when an assignment entry is missing the user struct" do
      assigns = %{
        histories: [
          entry(%{
            type: :assignment,
            from_user_id: nil,
            to_user_id: 99,
            to_user: nil
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ "Assigned to"
      assert html =~ "Unknown"
    end
  end

  describe "activity_log/1 — markers and scope" do
    test "outermost element scopes under .stride-screen" do
      assigns = %{histories: []}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ ~s(class="stride-screen")
    end
  end
end
