defmodule KanbanWeb.TargetLive.FormTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Targets

  @create_attrs %{name: "Q3 Launch", target_date: "2026-09-30", description: "ship it"}
  @invalid_attrs %{name: nil, target_date: nil, description: nil}

  defp goal_fixture(column, attrs) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  describe "new" do
    setup [:register_and_log_in_user]

    test "renders the current user's email as read-only owner", %{conn: conn, user: user} do
      {:ok, _live, html} = live(conn, ~p"/targets/new")
      assert html =~ user.email
      refute html =~ "Assigned Goals"
    end

    test "renders changeset errors on invalid input", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/targets/new")

      assert form_live
             |> form("#target-form", delivery_target: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates a target and redirects to its edit page with a flash", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/targets/new")

      {:ok, edit_live, html} =
        form_live
        |> form("#target-form", delivery_target: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn)

      assert edit_live.module == KanbanWeb.TargetLive.Form
      assert html =~ "Target created successfully"
      assert html =~ "Assigned Goals"
    end
  end

  describe "edit" do
    setup [:register_and_log_in_user]

    test "the owner loads the edit form", %{conn: conn, user: user} do
      target = delivery_target_fixture(user)
      {:ok, _live, html} = live(conn, ~p"/targets/#{target}/edit")

      assert html =~ target.name
      assert html =~ user.email
      assert html =~ "Available Goals"
    end

    test "a non-owner is redirected to /boards with an error flash", %{conn: conn} do
      other = user_fixture()
      target = delivery_target_fixture(other)

      assert {:error, {:live_redirect, %{to: "/boards", flash: flash}}} =
               live(conn, ~p"/targets/#{target}/edit")

      assert flash["error"] =~ "Only the target owner can edit this target"
    end

    test "assigns an available goal, moving it to the assigned list", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Ship API"})
      target = delivery_target_fixture(user)

      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      assert has_element?(form_live, "#assignable-goal-#{goal.id}")

      form_live
      |> element("#assignable-goal-#{goal.id} button", "Assign")
      |> render_click()

      assert has_element?(form_live, "#member-goal-#{goal.id}")
      refute has_element?(form_live, "#assignable-goal-#{goal.id}")

      scope = Scope.for_user(user)
      assert [assigned] = Targets.list_member_goals(scope, target)
      assert assigned.id == goal.id
    end

    test "unassigns an assigned goal, moving it back to available", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Ship API"})
      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      assert has_element?(form_live, "#member-goal-#{goal.id}")

      form_live
      |> element("#member-goal-#{goal.id} button", "Unassign")
      |> render_click()

      assert has_element?(form_live, "#assignable-goal-#{goal.id}")
      refute has_element?(form_live, "#member-goal-#{goal.id}")
      assert Targets.list_member_goals(scope, target) == []
    end
  end
end
