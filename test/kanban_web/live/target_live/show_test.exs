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
  alias Kanban.Targets

  defp goal_fixture(column, attrs) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
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
