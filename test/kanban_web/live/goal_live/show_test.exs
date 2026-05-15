defmodule KanbanWeb.GoalLive.ShowTest do
  @moduledoc """
  Mount + scoping contract tests for `KanbanWeb.GoalLive.Show`.
  """
  use KanbanWeb.ConnCase

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
      assert html =~ goal.identifier
      assert html =~ "Migrate the detail surface"
      assert html =~ board.name
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
end
