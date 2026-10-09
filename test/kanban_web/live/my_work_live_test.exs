defmodule KanbanWeb.MyWorkLiveTest do
  @moduledoc """
  Tests for `KanbanWeb.MyWorkLive` — the cross-board My Work queue at
  `/my-work` (W2237).
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Labels
  alias KanbanWeb.MyWorkLive

  describe "unauthenticated access" do
    test "redirects to the log-in page when the user is not signed in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/my-work")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "logged-in user" do
    setup [:register_and_log_in_user]

    test "shows tasks from two boards grouped by board", %{conn: conn, user: user, scope: scope} do
      alpha = board_fixture(user, %{name: "Alpha board"})
      beta = board_fixture(user, %{name: "Beta board"})

      alpha_task =
        task_fixture(column_fixture(alpha), %{title: "Alpha work", assigned_to_id: user.id})

      beta_task =
        task_fixture(column_fixture(beta), %{title: "Beta work", assigned_to_id: user.id})

      label = label_fixture(alpha, %{name: "frontend"})
      {:ok, _} = Labels.set_task_labels(scope, alpha_task, [label.id])

      {:ok, view, html} = live(conn, ~p"/my-work")

      assert html =~ "My Work"
      assert has_element?(view, "[data-my-work-board='#{alpha.id}']", "Alpha board")
      assert has_element?(view, "[data-my-work-board='#{beta.id}']", "Beta board")

      assert has_element?(
               view,
               "[data-my-work-board='#{alpha.id}'] a[href='/boards/#{alpha.id}/tasks/#{alpha_task.id}/edit']",
               alpha_task.identifier
             )

      assert has_element?(
               view,
               "[data-my-work-board='#{beta.id}'] [data-my-work-task='#{beta_task.id}']",
               "Beta work"
             )

      assert has_element?(
               view,
               "[data-my-work-task='#{alpha_task.id}'] [data-my-work-row-board]",
               "Alpha board"
             )

      assert has_element?(
               view,
               "[data-my-work-task='#{alpha_task.id}'] [data-label-chip]",
               "frontend"
             )

      # Alpha's section renders before Beta's.
      [_, after_alpha] = String.split(html, "data-my-work-board=\"#{alpha.id}\"", parts: 2)
      assert after_alpha =~ "data-my-work-board=\"#{beta.id}\""

      refute has_element?(view, "[data-my-work-empty]")
    end

    test "links goal-type tasks to the goal page", %{conn: conn, user: user} do
      board = board_fixture(user)
      goal = task_fixture(column_fixture(board), %{type: :goal, assigned_to_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/my-work")

      assert has_element?(view, "a[href='/boards/#{board.id}/goals/#{goal.id}']")
    end

    test "links a task on a read-only board to the board filtered to it, not the editor", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Boards.add_user_to_board(board, user, :read_only, owner)
      task = task_fixture(column_fixture(board), %{assigned_to_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/my-work")

      assert has_element?(
               view,
               "[data-my-work-task='#{task.id}'][href='/boards/#{board.id}?q=#{task.identifier}']"
             )

      refute has_element?(view, "a[href='/boards/#{board.id}/tasks/#{task.id}/edit']")
    end

    test "does not show another user's tasks", %{conn: conn, user: user} do
      other = user_fixture()
      board = board_fixture(user)
      {:ok, _} = Boards.add_user_to_board(board, other, :modify, user)

      task_fixture(column_fixture(board), %{
        title: "Someone else's task",
        assigned_to_id: other.id
      })

      {:ok, view, html} = live(conn, ~p"/my-work")

      refute html =~ "Someone else&#39;s task"
      assert has_element?(view, "[data-my-work-empty]")
    end

    test "shows the empty state when nothing is assigned", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/my-work")

      assert has_element?(view, "[data-my-work-empty]", "Nothing assigned to you")
      assert has_element?(view, "[data-my-work-count]", "0 tasks assigned to you")
      refute has_element?(view, "[data-my-work-board]")
    end

    test "highlights My Work in the side nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/my-work")

      [_, after_href] = String.split(html, ~s(href="/my-work"), parts: 2)
      [row_inner, _] = String.split(after_href, "</a>", parts: 2)

      assert row_inner =~ "var(--stride-orange)"
    end
  end

  describe "task_path/2" do
    test "routes work tasks to the board task editor and goals to the goal page" do
      board = %{id: 7}

      assert MyWorkLive.task_path(board, %{type: :work, id: 3}) == "/boards/7/tasks/3/edit"
      assert MyWorkLive.task_path(board, %{type: :defect, id: 4}) == "/boards/7/tasks/4/edit"
      assert MyWorkLive.task_path(board, %{type: :goal, id: 5}) == "/boards/7/goals/5"
    end

    test "routes a read-only member's tasks to the board filtered by identifier" do
      board = %{id: 7, user_access: :read_only}

      assert MyWorkLive.task_path(board, %{type: :work, id: 3, identifier: "W12"}) ==
               "/boards/7?q=W12"

      assert MyWorkLive.task_path(board, %{type: :goal, id: 5, identifier: "G1"}) ==
               "/boards/7/goals/5"

      assert MyWorkLive.task_path(%{id: 7, user_access: :modify}, %{type: :work, id: 3}) ==
               "/boards/7/tasks/3/edit"
    end
  end

  describe "priority_label/1" do
    test "translates each priority and falls back to an empty string" do
      assert MyWorkLive.priority_label(:critical) == "Critical"
      assert MyWorkLive.priority_label(:high) == "High"
      assert MyWorkLive.priority_label(:medium) == "Medium"
      assert MyWorkLive.priority_label(:low) == "Low"
      assert MyWorkLive.priority_label(nil) == ""
    end
  end
end
