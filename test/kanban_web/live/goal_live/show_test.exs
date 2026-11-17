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

      # W1392: the main/sidebar split carries the goal-detail-layout class that
      # the app.css <1024px rule wraps so the sidebar stacks below the hierarchy
      # on mobile instead of squeezing it into horizontal overflow.
      assert html =~ "goal-detail-layout"
      assert html =~ "goal-detail-aside"
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
      # Sub-24h earliest signal → throughput unit collapses to hourly, and a
      # goal inserted just now gets the 2-bucket minimum (D426).
      assert html =~ "Throughput · last 2 hours"
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
      # so bucket_unit/2 returns :day and bucket_label/2 + range_label/3
      # (LocalTime :short_date) exercise the daily-cadence formatting branch.
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

      # The day-cadence label is "Mon D, YYYY — Mon D, YYYY": LocalTime's
      # :short_date in the viewer's zone and language (en here).
      assert html =~ ~r/[A-Z][a-z]{2} \d{1,2}, \d{4} — [A-Z][a-z]{2} \d{1,2}, \d{4}/
    end
  end

  describe "velocity sparkline — bucket count follows the goal's age" do
    setup [:register_and_log_in_user]

    test "shortens the daily sparkline to the goal's age", %{conn: conn, user: user} do
      {board, goal} = aged_goal(user, 2 * 86_400 + 60)

      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 3 days"
      assert length(point_ys(html)) == 3
    end

    test "caps the daily sparkline at 12 buckets", %{conn: conn, user: user} do
      {board, goal} = aged_goal(user, 20 * 86_400)
      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 12 days"
      assert length(point_ys(html)) == 12

      {board, goal} = aged_goal(user, 86_400 + 3600)
      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 2 days"
      assert length(point_ys(html)) == 2
    end

    test "shortens the hourly sparkline to the goal's age", %{conn: conn, user: user} do
      {board, goal} = aged_goal(user, 3 * 3600 + 60)

      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 4 hours"
      assert length(point_ys(html)) == 4
    end

    test "counts a completion older than the goal's earliest signal",
         %{conn: conn, user: user} do
      # The goal row is 2 hours old but a child finished 3 days ago: the
      # completion is itself the earliest signal, so it widens the span to
      # 4 daily buckets and lands in the oldest (leftmost) one.
      {board, goal} = aged_goal(user, 2 * 3600, completed_age: 3 * 86_400 + 60)

      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 4 days"
      # PulseSparkline puts the maximum at y=1 and zero at y=41 (height 42).
      assert point_ys(html) == ["1", "41", "41", "41"]
    end

    test "renders a zero sparkline sized to a new goal", %{conn: conn, user: user} do
      {board, goal} = aged_goal(user, 0)

      html = velocity_html(conn, board, goal)

      assert html =~ "Throughput · last 2 hours"
      assert point_ys(html) == ["41", "41"]
    end

    test "caption range matches the shortened bucket span", %{conn: conn, user: user} do
      {board, goal} = aged_goal(user, 2 * 86_400 + 60)

      before = DateTime.utc_now()
      html = velocity_html(conn, board, goal)
      later = DateTime.utc_now()

      [_, caption_start] = Regex.run(~r/<span>([^<]+) — [^<]+<\/span>/, html)

      expected =
        for now <- [before, later] do
          now |> DateTime.add(-3 * 86_400, :second) |> KanbanWeb.LocalTime.format(:short_date)
        end

      assert caption_start in expected
    end
  end

  # A goal (with one open child) whose inserted_at is `age_seconds` ago.
  # `completed_age:` also completes the child that many seconds ago.
  defp aged_goal(user, age_seconds, opts \\ []) do
    board = board_fixture(user)
    column = column_fixture(board)

    {:ok, %{goal: goal, child_tasks: [child]}} =
      Tasks.create_goal_with_tasks(
        column,
        %{"title" => "Aged goal", "created_by_id" => user.id},
        [%{"title" => "Child", "type" => "work", "created_by_id" => user.id}]
      )

    seconds_ago = fn s ->
      DateTime.utc_now() |> DateTime.add(-s, :second) |> DateTime.truncate(:second)
    end

    from(t in Kanban.Tasks.Task, where: t.id == ^goal.id)
    |> Kanban.Repo.update_all(
      set: [inserted_at: age_seconds |> seconds_ago.() |> DateTime.to_naive(), claimed_at: nil]
    )

    if completed_age = opts[:completed_age] do
      from(t in Kanban.Tasks.Task, where: t.id == ^child.id)
      |> Kanban.Repo.update_all(
        set: [status: :completed, completed_at: seconds_ago.(completed_age)]
      )
    end

    {board, goal}
  end

  defp velocity_html(conn, board, goal) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")
    view |> element("[data-goal-velocity]") |> render()
  end

  defp point_ys(html) do
    ~r/<circle[^>]*\scy="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, y] -> y end)
  end

  describe "local time — timestamps follow the viewer's zone and language" do
    setup [:register_and_log_in_user]

    test "renders timestamps in the viewer's timezone", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-07-15 16:30:00])

      conn = init_test_session(conn, %{"timezone" => "America/Toronto"})
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # 16:30 UTC is 12:30 PM in Toronto (EDT in July).
      assert html =~ "July 15, 2026 at 12:30 PM"
      refute html =~ "4:30 PM"

      assert view |> element("[data-goal-last-activity]") |> render() =~
               ~s(title="July 15, 2026 at 12:30 PM EDT")
    end

    test "rolls a late-evening timestamp back to the local day", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 02:15:00])

      conn = init_test_session(conn, %{"timezone" => "America/Los_Angeles"})
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # 02:15 UTC on the 11th is still the evening of the 10th in Los Angeles.
      assert html =~ "November 10, 2026 at 6:15 PM"
      refute html =~ "November 11, 2026"

      assert view |> element("[data-goal-last-activity]") |> render() =~
               ~s(title="November 10, 2026 at 6:15 PM PST")
    end

    test "falls back to UTC for an unknown zone", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 02:15:00])

      conn =
        conn
        |> init_test_session(%{"timezone" => "Mars/Olympus"})
        |> put_connect_params(%{"timezone" => "Not/AZone"})

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "November 11, 2026 at 2:15 AM"

      assert view |> element("[data-goal-last-activity]") |> render() =~
               ~s(datetime="2026-11-11T02:15:00Z")
    end

    test "renders nothing for a nil timestamp", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 02:15:00])

      from(h in Kanban.Tasks.TaskHistory, where: h.task_id == ^goal.id)
      |> Kanban.Repo.delete_all()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      refute view |> element("[data-goal-activity]") |> render() =~ "<time"

      # A goal with no recorded activity: the sidebar shows a dash, no <time>.
      sidebar =
        render_component(&KanbanWeb.GoalSidebar.goal_sidebar/1,
          metrics: sidebar_metrics(%{last_activity: nil})
        )

      refute sidebar =~ "data-goal-last-activity"
      refute sidebar =~ "<time"
      assert sidebar =~ "—"
    end

    test "uses the session timezone and locale on mount", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 04:56:00])

      conn = init_test_session(conn, %{"locale" => "de", "timezone" => "America/Toronto"})
      path = ~p"/boards/#{board}/goals/#{goal.id}"

      static_html = conn |> get(path) |> html_response(200)
      {:ok, _view, connected_html} = live(conn, path)

      for html <- [static_html, connected_html] do
        assert html =~ "10. November 2026, 23:56"
        assert html =~ ~s(title="10. November 2026, 23:56 EST")
        # The daily sparkline caption uses the German short date on both ends.
        assert html =~ ~r/\d{1,2}\. \S+ \d{4} — \d{1,2}\. \S+ \d{4}/
        refute html =~ ~r/\d{1,2}:\d{2} (AM|PM)/
      end
    end

    test "renders French month names on the goal page in fr", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 04:56:00])

      conn = init_test_session(conn, %{"locale" => "fr", "timezone" => "America/Toronto"})
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      assert html =~ "10 novembre 2026 à 23:56"

      assert view |> element("[data-goal-last-activity]") |> render() =~
               ~s(title="10 novembre 2026 à 23:56 EST")

      refute html =~ "November"
    end

    test "renders the hourly sparkline clock in the viewer's zone and language",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, %{goal: goal, child_tasks: [child]}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Fresh goal", "created_by_id" => user.id},
          [%{"title" => "Just started", "type" => "work", "created_by_id" => user.id}]
        )

      one_hour_ago = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)

      from(t in Kanban.Tasks.Task, where: t.id == ^child.id)
      |> Kanban.Repo.update_all(set: [claimed_at: one_hour_ago])

      conn = init_test_session(conn, %{"locale" => "de", "timezone" => "America/Toronto"})
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      # The caption is "HH:MM — HH:MM": the German 24-hour clock, shifted to
      # Toronto. The goal was inserted just now (a child's claim is not an
      # age signal), so the sparkline is the 2-bucket minimum (D426).
      [_, from_h, from_m, to_h, to_m] =
        Regex.run(~r/(\d{2}):(\d{2}) — (\d{2}):(\d{2})/, html)

      refute html =~ ~r/\d{1,2}:\d{2} (AM|PM)/

      minutes = fn h, m -> String.to_integer(h) * 60 + String.to_integer(m) end
      local_now = DateTime.now!("America/Toronto")
      now_minutes = local_now.hour * 60 + local_now.minute

      # The right end is the local "now" (allowing a minute's rollover); the
      # left end is two hours before it.
      assert Integer.mod(now_minutes - minutes.(to_h, to_m), 1440) in [0, 1]
      assert Integer.mod(minutes.(to_h, to_m) - minutes.(from_h, from_m), 1440) == 120
    end

    test "keeps an ISO 8601 UTC datetime attribute", %{conn: conn, user: user} do
      {board, goal} = goal_stamped_at(user, ~N[2026-11-11 04:56:00])

      conn = init_test_session(conn, %{"timezone" => "Asia/Tokyo"})
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/goals/#{goal.id}")

      last_activity = view |> element("[data-goal-last-activity]") |> render()
      assert last_activity =~ ~s(datetime="2026-11-11T04:56:00Z")
      assert last_activity =~ ~s(title="November 11, 2026 at 1:56 PM JST")
      refute html =~ "+09:00"
    end
  end

  # A goal with one child whose updated_at, inserted_at and activity-log
  # history are all pinned to `at` (a UTC NaiveDateTime).
  defp goal_stamped_at(user, at) do
    board = board_fixture(user)
    column = column_fixture(board)

    {:ok, %{goal: goal, child_tasks: [child]}} =
      Tasks.create_goal_with_tasks(
        column,
        %{"title" => "Local time goal", "created_by_id" => user.id},
        [%{"title" => "Child", "type" => "work", "created_by_id" => user.id}]
      )

    from(t in Kanban.Tasks.Task, where: t.id in ^[goal.id, child.id])
    |> Kanban.Repo.update_all(set: [updated_at: at, inserted_at: at])

    Kanban.Repo.insert!(%Kanban.Tasks.TaskHistory{
      task_id: goal.id,
      type: :creation,
      inserted_at: at
    })

    from(h in Kanban.Tasks.TaskHistory, where: h.task_id in ^[goal.id, child.id])
    |> Kanban.Repo.update_all(set: [inserted_at: at])

    {board, goal}
  end

  defp sidebar_metrics(overrides) do
    Map.merge(
      %{
        percent: 0,
        done: 0,
        total: 1,
        in_flight: 0,
        ready: 1,
        backlog: 0,
        blocked: 0,
        contributor_count: 0,
        days_in_flight: nil,
        time_spent_minutes: 0,
        avg_cycle_minutes: 0,
        last_activity: ~U[2026-11-11 04:56:00Z],
        sparkline_data: List.duplicate(0, 12),
        sparkline_label: "",
        sparkline_unit: :day,
        sparkline_count: 12
      },
      overrides
    )
  end
end
