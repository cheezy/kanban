defmodule KanbanWeb.GoalLive.ShowTest do
  @moduledoc """
  Mount + scoping contract tests for `KanbanWeb.GoalLive.Show`.
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "mount/3 — happy path" do
    setup [:register_and_log_in_user]

    test "renders the goal page when the user has access to the board",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Migrate the detail surface", "created_by_id" => user.id},
          [%{"title" => "Child A", "type" => "work", "created_by_id" => user.id}]
        )

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "data-goal-show"
      assert html =~ "data-goal-progress-header"
      assert html =~ "data-goal-hierarchy"
      assert html =~ "data-goal-sidebar"
      assert html =~ "data-goal-activity"
      assert html =~ goal.identifier
      assert html =~ "Migrate the detail surface"
      assert html =~ board.name
    end

    test "groups children by status with a section per status that has any children",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [first | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Body Goal", "created_by_id" => user.id},
          [
            %{"title" => "Child One", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Child Two", "type" => "work", "created_by_id" => user.id}
          ]
        )

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "Child One"
      assert html =~ "Child Two"
      assert html =~ first.identifier
      # Newly-created children default to :open, which collapses to :backlog
      # via normalize_status/1 so they render inside the Backlog section.
      assert html =~ ~r/>\s*Backlog\s*</
    end

    test "renders the empty-state when the goal has no children",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Lonely Goal",
          "created_by_id" => user.id
        })

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "This goal has no children yet."
      refute html =~ "data-goal-child-row"
    end

    test "open_child event navigates to the task edit URL",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [child | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Nav Goal", "created_by_id" => user.id},
          [%{"title" => "Click me", "type" => "work", "created_by_id" => user.id}]
        )

      {:ok, live, _html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert {:error, {:live_redirect, %{to: edit_path}}} =
               render_click(live, "open_child", %{"id" => child.id})

      assert edit_path == ~p"/boards/#{board}/tasks/#{child.id}/edit"
    end

    test "page_title combines identifier and goal title",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Build the goal view",
          "created_by_id" => user.id
        })

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ goal.identifier
      assert html =~ "Build the goal view"
    end
  end

  describe "mount/3 — unauthorized" do
    setup [:register_and_log_in_user]

    test "redirects with flash when the goal belongs to another user's board",
         %{conn: conn} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Forbidden Goal",
          "created_by_id" => other_user.id
        })

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Goal not found"}}}} =
               live(conn, ~p"/boards/#{board}/goals/#{goal.id}")
    end

    test "redirects when goal_id does not exist",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Goal not found"}}}} =
               live(conn, ~p"/boards/#{board}/goals/99999999")
    end

    test "redirects when the id refers to a non-goal task",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Just a work task"})

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Goal not found"}}}} =
               live(conn, ~p"/boards/#{board}/goals/#{task.id}")
    end

    test "redirects when goal belongs to a different board",
         %{conn: conn, user: user} do
      board_a = board_fixture(user, %{name: "Board A"})
      board_b = board_fixture(user, %{name: "Board B"})
      column_b = column_fixture(board_b)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column_b, %{
          "title" => "Goal on B",
          "created_by_id" => user.id
        })

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Goal not found"}}}} =
               live(conn, ~p"/boards/#{board_a}/goals/#{goal.id}")
    end
  end

  describe "mount/3 — anonymous" do
    test "redirects to the login page", %{conn: conn} do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Some Goal",
          "created_by_id" => user.id
        })

      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "sidebar metrics — counts" do
    setup [:register_and_log_in_user]

    test "renders done/total reflecting the children's status distribution",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [done | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Counts Goal", "created_by_id" => user.id},
          [
            %{"title" => "One", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Two", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Three", "type" => "work", "created_by_id" => user.id}
          ]
        )

      # Mark one child completed so done=1, total=3, percent=33.
      from(t in Kanban.Tasks.Task, where: t.id == ^done.id)
      |> Kanban.Repo.update_all(set: [status: :completed, completed_at: DateTime.utc_now()])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "data-goal-sidebar"
      assert html =~ "1/3"
    end

    test "renders Contributors count from the goal + children authors",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Contributors Goal", "created_by_id" => user.id},
          [%{"title" => "One", "type" => "work", "created_by_id" => user.id}]
        )

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "Contributors"
    end

    test "shows the Throughput heading and a sparkline marker",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Throughput Goal",
          "created_by_id" => user.id
        })

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "data-goal-velocity"
      assert html =~ ~r/Throughput\s·\s/
    end

    test "renders the Time section with --- placeholders for an idle goal",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(column, %{
          "title" => "Idle Goal",
          "created_by_id" => user.id
        })

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "Days in flight"
      assert html =~ "Time spent"
      assert html =~ "Avg cycle"
      assert html =~ "Last activity"
    end
  end

  describe "sidebar metrics — time" do
    setup [:register_and_log_in_user]

    test "sums time_spent_minutes across children",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [c1, c2 | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Time Goal", "created_by_id" => user.id},
          [
            %{"title" => "First", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Second", "type" => "work", "created_by_id" => user.id}
          ]
        )

      from(t in Kanban.Tasks.Task, where: t.id in ^[c1.id, c2.id])
      |> Kanban.Repo.update_all(set: [time_spent_minutes: 45])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # 45 + 45 = 90 minutes → 1h 30m
      assert html =~ "1h 30m"
    end

    test "computes the avg cycle from done children only",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [done, in_progress | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Avg Goal", "created_by_id" => user.id},
          [
            %{"title" => "Finished", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Going", "type" => "work", "created_by_id" => user.id}
          ]
        )

      # done has 120 minutes, in_progress has 60 — avg should be 120m, not 90m.
      from(t in Kanban.Tasks.Task, where: t.id == ^done.id)
      |> Kanban.Repo.update_all(
        set: [status: :completed, completed_at: DateTime.utc_now(), time_spent_minutes: 120]
      )

      from(t in Kanban.Tasks.Task, where: t.id == ^in_progress.id)
      |> Kanban.Repo.update_all(set: [time_spent_minutes: 60])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "Avg cycle"
      # Total spent across both = 180m = 3h, avg of done only = 2h.
      assert html =~ "3h"
      assert html =~ "2h"
    end

    test "renders 'today' for a goal claimed less than 24h ago",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [child | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Hot Goal", "created_by_id" => user.id},
          [%{"title" => "Just started", "type" => "work", "created_by_id" => user.id}]
        )

      # Stamp the child with a recent claim so the days-in-flight calculation
      # has a non-nil earliest signal.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      one_hour_ago = DateTime.add(now, -3600, :second)

      from(t in Kanban.Tasks.Task, where: t.id == ^child.id)
      |> Kanban.Repo.update_all(set: [claimed_at: one_hour_ago])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "today"
      # Sub-24h earliest signal → throughput unit collapses to hourly.
      assert html =~ "Throughput · last 12 hours"
    end
  end

  describe "mount/3 — malformed id" do
    setup [:register_and_log_in_user]

    test "redirects to /boards when goal_id is non-numeric",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board)

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Goal not found"}}}} =
               live(conn, ~p"/boards/#{board}/goals/not-a-number")
    end
  end

  describe "status grouping — multiple statuses" do
    setup [:register_and_log_in_user]

    test "renders a Done section for children with status :completed",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [done, other | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Mixed-status Goal", "created_by_id" => user.id},
          [
            %{"title" => "Finished", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Open", "type" => "work", "created_by_id" => user.id}
          ]
        )

      from(t in Kanban.Tasks.Task, where: t.id == ^done.id)
      |> Kanban.Repo.update_all(set: [status: :completed, completed_at: DateTime.utc_now()])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ ~r/>\s*Done\s*</
      assert html =~ ~r/>\s*Backlog\s*</
      assert html =~ "Finished"
      assert html =~ "Open"
      # Both children render
      assert html =~ done.identifier
      assert html =~ other.identifier
    end

    test "renders a Doing section for children with :in_progress status",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [doing | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Doing-status Goal", "created_by_id" => user.id},
          [
            %{"title" => "Doing Child", "type" => "work", "created_by_id" => user.id}
          ]
        )

      from(t in Kanban.Tasks.Task, where: t.id == ^doing.id)
      |> Kanban.Repo.update_all(set: [status: :in_progress])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ ~r/>\s*Doing\s*</
    end
  end

  describe "contributors band — agents" do
    setup [:register_and_log_in_user]

    test "renders agent avatars when children carry created_by_agent / completed_by_agent",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [creator, finisher | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Agent-touched Goal", "created_by_id" => user.id},
          [
            %{"title" => "Started By Agent", "type" => "work", "created_by_id" => user.id},
            %{"title" => "Finished By Agent", "type" => "work", "created_by_id" => user.id}
          ]
        )

      from(t in Kanban.Tasks.Task, where: t.id == ^creator.id)
      |> Kanban.Repo.update_all(set: [created_by_agent: "Claude"])

      from(t in Kanban.Tasks.Task, where: t.id == ^finisher.id)
      |> Kanban.Repo.update_all(set: [completed_by_agent: "Cursor"])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # The contributors band picks up both created_by_agent and
      # completed_by_agent values via agent_to_avatar/1.
      assert html =~ "data-goal-show"
      assert html =~ "Claude"
      assert html =~ "Cursor"
    end
  end

  describe "status grouping — column-name buckets" do
    setup [:register_and_log_in_user]

    test "places children in :ready, :in_progress, :review, :completed sections by column name",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      ready_col = column_fixture(board, %{name: "Ready"})
      doing_col = column_fixture(board, %{name: "Doing"})
      review_col = column_fixture(board, %{name: "Review"})
      done_col = column_fixture(board, %{name: "Done"})
      other_col = column_fixture(board, %{name: "Triage"})

      {:ok,
       %{
         goal: goal,
         child_tasks: [ready_child, doing_child, review_child, done_child, other_child]
       }} =
        Tasks.create_goal_with_tasks(
          ready_col,
          %{"title" => "Multi-column Goal", "created_by_id" => user.id},
          [
            %{"title" => "In Ready", "type" => "work", "created_by_id" => user.id},
            %{"title" => "In Doing", "type" => "work", "created_by_id" => user.id},
            %{"title" => "In Review", "type" => "work", "created_by_id" => user.id},
            %{"title" => "In Done", "type" => "work", "created_by_id" => user.id},
            %{"title" => "In Triage", "type" => "work", "created_by_id" => user.id}
          ]
        )

      from(t in Kanban.Tasks.Task, where: t.id == ^doing_child.id)
      |> Kanban.Repo.update_all(set: [column_id: doing_col.id])

      from(t in Kanban.Tasks.Task, where: t.id == ^review_child.id)
      |> Kanban.Repo.update_all(set: [column_id: review_col.id])

      from(t in Kanban.Tasks.Task, where: t.id == ^done_child.id)
      |> Kanban.Repo.update_all(set: [column_id: done_col.id])

      from(t in Kanban.Tasks.Task, where: t.id == ^other_child.id)
      |> Kanban.Repo.update_all(set: [column_id: other_col.id])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # All five children render somewhere
      assert html =~ ready_child.identifier
      assert html =~ doing_child.identifier
      assert html =~ review_child.identifier
      assert html =~ done_child.identifier
      assert html =~ other_child.identifier

      # status_dot/status_label emit the matching CSS variable per status
      assert html =~ "var(--st-ready)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-done)"
      # The "Triage" column falls through bucket_for's underscore clause to
      # :backlog, so the backlog dot variable is also present.
      assert html =~ "var(--st-backlog)"
    end

    test "places a child in :backlog when its column name is literally 'Backlog'",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      backlog_col = column_fixture(board, %{name: "Backlog"})

      {:ok, %{goal: goal, child_tasks: [child | _]}} =
        Tasks.create_goal_with_tasks(
          backlog_col,
          %{"title" => "Backlog-named Goal", "created_by_id" => user.id},
          [%{"title" => "In Backlog", "type" => "work", "created_by_id" => user.id}]
        )

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ child.identifier
      assert html =~ "var(--st-backlog)"
    end
  end

  describe "velocity sparkline — daily bucketing for older goals" do
    setup [:register_and_log_in_user]

    test "switches to the day bucket label when the goal's earliest signal is older than 24h",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [done | _]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Old Goal", "created_by_id" => user.id},
          [
            %{"title" => "Finished Long Ago", "type" => "work", "created_by_id" => user.id}
          ]
        )

      # Push the goal's inserted_at and the child's completed_at back 5 days
      # so bucket_unit/2 returns :day and bucket_label/2 + format_short_date/1
      # exercise the daily-cadence formatting branch.
      five_days_ago_naive =
        DateTime.utc_now()
        |> DateTime.add(-5 * 86_400, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      five_days_ago_dt =
        DateTime.utc_now() |> DateTime.add(-5 * 86_400, :second) |> DateTime.truncate(:second)

      from(t in Kanban.Tasks.Task, where: t.id == ^goal.id)
      |> Kanban.Repo.update_all(
        set: [
          inserted_at: five_days_ago_naive,
          claimed_at: five_days_ago_dt
        ]
      )

      from(t in Kanban.Tasks.Task, where: t.id == ^done.id)
      |> Kanban.Repo.update_all(set: [status: :completed, completed_at: five_days_ago_dt])

      {:ok, _live, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # The day-cadence label is "Mon DD — Mon DD" via Calendar.strftime("%b %d").
      # Assert the dash-separator format characteristic of the daily branch.
      assert html =~ ~r/[A-Z][a-z]{2} \d{1,2} — [A-Z][a-z]{2} \d{1,2}/
    end
  end
end
