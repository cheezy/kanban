defmodule KanbanWeb.TargetLive.ShowTest do
  @moduledoc """
  Mount + scoping contract tests for `KanbanWeb.TargetLive.Show` — the
  `/targets/:id` member-goals drill-down.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Tasks.Task

  defp goal_fixture(column, attrs) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  defp complete_task(task) do
    {:ok, done} =
      task
      |> Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()

    done
  end

  defp count_occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  describe "mount/3 — happy path" do
    setup [:register_and_log_in_user]

    test "renders the target name and its member goals, each linking to the goal drill-down",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Ship the migration"})
      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Scope.for_user(user)

      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "Q3 Launch"
      assert html =~ "Ship the migration"
      assert html =~ goal.identifier
      # Each member goal links to its OWN board's goal drill-down.
      assert html =~ ~p"/boards/#{board}/goals/#{goal}"
    end

    test "renders an Edit link pointing to the target's edit page", %{conn: conn, user: user} do
      target = delivery_target_fixture(user, %{name: "Q3 Launch"})

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ ~p"/targets/#{target}/edit"
      assert html =~ "Edit target"
    end

    test "renders the goals grid (not the empty state) when the target has member goals",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Only Goal"})
      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      refute html =~ "No goals in this target yet."
      assert html =~ "Only Goal"
      assert html =~ "data-target-goals"
    end
  end

  describe "mount/3 — hero and goals table" do
    setup [:register_and_log_in_user]

    test "renders the TargetProgressHeader hero with the aggregate percentage",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Ship it"})
      # 1 of 2 children complete => 50%.
      _incomplete = task_fixture(column, %{parent_id: goal.id})
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "data-target-progress-header"
      assert html =~ "Q3 Launch"
      assert html =~ "50%"
      assert html =~ "1 of 2 complete"
    end

    test "renders one TargetGoalRow per member goal, each linking to its goal drill-down",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal_a = goal_fixture(column, %{title: "Goal Alpha"})
      goal_b = goal_fixture(column, %{title: "Goal Beta"})

      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_a, target)
      assert {:ok, _} = Targets.assign_goal(scope, goal_b, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "Goal Alpha"
      assert html =~ "Goal Beta"
      assert count_occurrences(html, "data-target-goal-row") == 2
      assert html =~ ~p"/boards/#{board}/goals/#{goal_a}"
      assert html =~ ~p"/boards/#{board}/goals/#{goal_b}"
    end

    test "aggregates completed/total across multiple member goals in the hero",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      goal_a = goal_fixture(column, %{title: "Alpha"})
      complete_task(task_fixture(column, %{parent_id: goal_a.id}))
      _a_incomplete = task_fixture(column, %{parent_id: goal_a.id})

      goal_b = goal_fixture(column, %{title: "Beta"})
      complete_task(task_fixture(column, %{parent_id: goal_b.id}))

      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_a, target)
      assert {:ok, _} = Targets.assign_goal(scope, goal_b, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      # 2 of 3 across both goals => 67%.
      assert html =~ "2 of 3 complete"
      assert html =~ "67%"
    end

    test "renders the hero at 0% and an empty table (no rows) for a memberless target the owner views",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user, %{name: "Empty Target"})

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "data-target-progress-header"
      assert html =~ "Empty Target"
      assert html =~ "0%"
      assert html =~ "No goals in this target yet."
      refute html =~ "data-target-goal-row"
    end
  end

  describe "mount/3 — scoping" do
    setup [:register_and_log_in_user]

    test "redirects with a flash when the target's only goal is on an inaccessible board",
         %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)
      other_column = column_fixture(other_board)
      goal = goal_fixture(other_column, %{title: "Secret Goal"})
      target = delivery_target_fixture(other_user)
      other_scope = Scope.for_user(other_user)

      assert {:ok, _} = Targets.assign_goal(other_scope, goal, target)

      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => "Target not found"}}}} =
               live(conn, ~p"/targets/#{target}")
    end

    test "lists only the member goals on boards the viewer can access",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_goal = goal_fixture(column, %{title: "Visible Goal"})

      other_user = user_fixture()
      other_board = board_fixture(other_user)
      other_column = column_fixture(other_board)
      hidden_goal = goal_fixture(other_column, %{title: "Hidden Goal"})

      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      other_scope = Scope.for_user(other_user)
      assert {:ok, _} = Targets.assign_goal(scope, visible_goal, target)
      assert {:ok, _} = Targets.assign_goal(other_scope, hidden_goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "Visible Goal"
      refute html =~ "Hidden Goal"
    end
  end

  describe "mount/3 — anonymous" do
    test "redirects to the login page", %{conn: conn} do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Some Goal"})
      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/targets/#{target}")
      assert redirect_to =~ "/users/log-in"
    end
  end
end
