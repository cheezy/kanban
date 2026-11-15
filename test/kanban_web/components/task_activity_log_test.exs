defmodule KanbanWeb.TaskActivityLogTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TaskActivityLog.activity_log/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory
  alias KanbanWeb.LocalTime
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

  # Renders the log in the test process, so the zone put here and the locale
  # set here are the ones `<.local_time>` reads.
  defp render_log(histories, zone, locale \\ "en") do
    LocalTime.put_timezone(zone)
    assigns = %{histories: histories}

    Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
      rendered_to_string(~H"""
      <TaskActivityLog.activity_log histories={@histories} />
      """)
    end)
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

  describe "activity_log/1 — heading" do
    test "renders its own History heading by default" do
      assigns = %{histories: [entry(%{type: :creation})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} />
        """)

      assert html =~ ~r/<h2[^>]*>\s*History\s*<\/h2>/
    end

    test "omits the heading when the caller renders its own, keeping the entries" do
      assigns = %{histories: [entry(%{type: :creation})]}

      html =
        rendered_to_string(~H"""
        <TaskActivityLog.activity_log histories={@histories} heading={false} />
        """)

      refute html =~ "<h2"
      refute html =~ "History"
      assert html =~ "Created"
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

  describe "activity_log/1 — local time" do
    test "renders timestamps in the viewer's timezone" do
      html =
        render_log([entry(%{inserted_at: ~U[2026-05-11 14:32:00Z]})], "America/Toronto")

      assert html =~ "May 11, 2026 at 10:32 AM"
      refute html =~ "2:32 PM"
    end

    test "rolls a late-evening timestamp back to the local day" do
      html =
        render_log([entry(%{inserted_at: ~U[2026-11-11 04:56:00Z]})], "America/Toronto")

      assert html =~ "November 10, 2026 at 11:56 PM"
      refute html =~ "November 11"
    end

    test "treats a NaiveDateTime as UTC before shifting it" do
      html =
        render_log([entry(%{inserted_at: ~N[2026-11-11 04:56:00]})], "America/Toronto")

      assert html =~ "November 10, 2026 at 11:56 PM"
    end

    test "falls back to UTC for an unknown zone" do
      html = render_log([entry(%{inserted_at: ~U[2026-05-11 14:32:00Z]})], "Not/AZone")

      assert html =~ "May 11, 2026 at 2:32 PM"
      assert html =~ ~s(title="May 11, 2026 at 2:32 PM UTC")
    end

    test "renders nothing for a nil timestamp" do
      html = render_log([entry(%{inserted_at: nil})], "America/Toronto")

      assert html =~ "Created"
      refute html =~ "<time"
    end

    test "renders nothing for a value that is not a timestamp" do
      html = render_log([entry(%{inserted_at: "yesterday"})], "America/Toronto")

      assert html =~ "Created"
      refute html =~ "<time"
      refute html =~ "yesterday"
    end

    test "renders German month names and a 24-hour clock in de" do
      html =
        render_log([entry(%{inserted_at: ~U[2026-05-11 14:32:00Z]})], "Europe/Berlin", "de")

      assert html =~ "11. Mai 2026, 16:32"
      refute html =~ "May"
      refute html =~ "PM"
    end

    test "shows the local zone abbreviation either side of a DST change" do
      before_change =
        render_log([entry(%{inserted_at: ~U[2026-03-08 06:30:00Z]})], "America/Toronto")

      after_change =
        render_log([entry(%{inserted_at: ~U[2026-03-08 07:30:00Z]})], "America/Toronto")

      assert before_change =~ "March 8, 2026 at 1:30 AM"
      assert before_change =~ ~s(title="March 8, 2026 at 1:30 AM EST")
      assert after_change =~ "March 8, 2026 at 3:30 AM"
      assert after_change =~ ~s(title="March 8, 2026 at 3:30 AM EDT")
    end

    test "keeps an ISO 8601 UTC datetime attribute" do
      html =
        render_log(
          [
            entry(%{type: :creation, inserted_at: ~U[2026-11-11 04:56:00Z]}),
            entry(%{
              type: :move,
              from_column: "Ready",
              to_column: "Doing",
              inserted_at: ~N[2026-05-11 14:32:00]
            })
          ],
          "America/Toronto",
          "ja"
        )

      assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
      assert html =~ ~s(datetime="2026-05-11T14:32:00Z")
      assert html =~ "2026年11月10日 23:56"
      assert html =~ "2026年5月11日 10:32"
    end
  end

  describe "activity_log/1 — on mount" do
    setup :register_and_log_in_user

    test "uses the session timezone and locale on mount", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Local time goal", "created_by_id" => user.id},
          [%{"title" => "Child", "type" => "work", "created_by_id" => user.id}]
        )

      set_history_time(goal.id, ~N[2026-11-11 04:56:00])
      conn = init_test_session(conn, %{"locale" => "de", "timezone" => "America/Toronto"})
      path = ~p"/boards/#{board}/goals/#{goal.id}"

      static_html = conn |> get(path) |> html_response(200)
      {:ok, _view, connected_html} = live(conn, path)

      for html <- [static_html, connected_html] do
        assert html =~ "10. November 2026, 23:56"
        assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
        refute html =~ "11:56 PM"
      end
    end

    test "the task detail view in ja renders every timestamp in year-month-day order",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      task
      |> Ecto.Changeset.change(
        inserted_at: ~N[2026-11-10 22:00:00],
        claimed_at: ~U[2026-11-11 04:56:00Z]
      )
      |> Repo.update!()

      set_history_time(task.id, ~N[2026-11-11 04:56:00])

      %TaskComment{task_id: task.id}
      |> TaskComment.changeset(%{content: "A comment"})
      |> Ecto.Changeset.put_change(:inserted_at, ~N[2026-11-11 04:56:00])
      |> Repo.insert!()

      conn = init_test_session(conn, %{"locale" => "ja", "timezone" => "Asia/Tokyo"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      render_hook(view, "view_task", %{"id" => to_string(task.id)})
      send(view.pid, {:show_task_modal, task.id})

      html = view |> element("#task-modal-wrapper-#{task.id}") |> render()

      # History and the aside's Claimed row: 04:56 UTC is 13:56 in Tokyo.
      assert html =~ "2026年11月11日 13:56"
      # The aside's Created row (:short_date): 22:00 UTC is the next day in Tokyo.
      assert html =~ "2026/11/11"
      # The comment's tooltip carries the local time and zone abbreviation.
      assert html =~ ~s(title="2026年11月11日 13:56 JST")
      refute html =~ ~r/(January|November|\bAM\b|\bPM\b)/
      refute html =~ " UTC"
    end
  end

  describe "edit form history — on mount" do
    setup :register_and_log_in_user

    test "the edit form's history renders in the session timezone and locale",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)
      set_history_time(task.id, ~N[2026-11-11 04:56:00])

      conn = init_test_session(conn, %{"locale" => "de", "timezone" => "America/Toronto"})
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert html =~ "10. November 2026, 23:56"
      assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
      refute html =~ "11:56 PM"
    end
  end

  defp set_history_time(task_id, inserted_at) do
    Repo.insert!(%TaskHistory{task_id: task_id, type: :creation, inserted_at: inserted_at})

    from(h in TaskHistory, where: h.task_id == ^task_id)
    |> Repo.update_all(set: [inserted_at: inserted_at])
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
