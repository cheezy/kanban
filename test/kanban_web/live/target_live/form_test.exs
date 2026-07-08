defmodule KanbanWeb.TargetLive.FormTest do
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
  alias Kanban.Targets.DeliveryTarget

  @create_attrs %{name: "Q3 Launch", target_date: "2026-09-30", description: "ship it"}
  @update_attrs %{name: "Renamed Launch", target_date: "2026-12-31", description: "revised scope"}
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

    test "submitting invalid input re-renders the form and creates no target",
         %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/targets/new")

      html =
        form_live
        |> form("#target-form", delivery_target: @invalid_attrs)
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      # Still on the form (no redirect happened) and nothing was persisted.
      assert form_live.module == KanbanWeb.TargetLive.Form
      assert Repo.aggregate(DeliveryTarget, :count) == 0
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

    test "the hide-archived checkbox defaults to checked, hiding archived goals, and toggles them",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      live_goal = goal_fixture(column, %{title: "Live goal"})
      archived_goal = goal_fixture(column, %{title: "Archived goal"})
      {:ok, _} = Kanban.Tasks.archive_task(archived_goal)
      target = delivery_target_fixture(user)

      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      live_row = "[data-assignable-goals] #target-goal-manage-row-#{live_goal.id}"
      archived_row = "[data-assignable-goals] #target-goal-manage-row-#{archived_goal.id}"

      # Default: the checkbox is checked, so archived goals are hidden.
      assert has_element?(form_live, "[data-hide-archived-toggle][checked]")
      assert has_element?(form_live, live_row)
      refute has_element?(form_live, archived_row)

      # Unchecking the box reveals the archived goal alongside the live one.
      form_live |> element("[data-hide-archived-toggle]") |> render_click()
      assert has_element?(form_live, live_row)
      assert has_element?(form_live, archived_row)

      # Re-checking hides it again.
      form_live |> element("[data-hide-archived-toggle]") |> render_click()
      refute has_element?(form_live, archived_row)
    end

    test "the owner edits the scalar fields, persisting them and redirecting to /boards",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user, %{name: "Original"})
      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      {:ok, _boards_live, html} =
        form_live
        |> form("#target-form", delivery_target: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "Target updated successfully"

      scope = Scope.for_user(user)
      {:ok, updated} = Targets.get_owned_target(scope, target.id)
      assert updated.name == "Renamed Launch"
      assert updated.target_date == ~D[2026-12-31]
      assert updated.description == "revised scope"
    end

    test "submitting invalid edits re-renders the form and leaves the target unchanged",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user, %{name: "Keep Me"})
      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      html =
        form_live
        |> form("#target-form", delivery_target: @invalid_attrs)
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert form_live.module == KanbanWeb.TargetLive.Form

      scope = Scope.for_user(user)
      {:ok, reloaded} = Targets.get_owned_target(scope, target.id)
      assert reloaded.name == "Keep Me"
    end

    test "flashes an error when assigning a goal on an inaccessible board",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user)

      other = user_fixture()
      other_board = board_fixture(other)
      other_column = column_fixture(other_board)
      other_goal = goal_fixture(other_column, %{title: "Off-limits"})

      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      html = render_hook(form_live, "assign_goal", %{"goal_id" => to_string(other_goal.id)})

      assert html =~ "Could not assign goal"
      scope = Scope.for_user(user)
      assert Targets.list_member_goals(scope, target) == []
    end

    test "flashes an error when unassigning a goal on an inaccessible board",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user)

      other = user_fixture()
      other_board = board_fixture(other)
      other_column = column_fixture(other_board)
      other_goal = goal_fixture(other_column, %{title: "Off-limits"})

      {:ok, form_live, _html} = live(conn, ~p"/targets/#{target}/edit")

      html = render_hook(form_live, "unassign_goal", %{"goal_id" => to_string(other_goal.id)})

      assert html =~ "Could not unassign goal"
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

      assert has_element?(
               form_live,
               "[data-assignable-goals] #target-goal-manage-row-#{goal.id}"
             )

      form_live
      |> element("[data-assignable-goals] #target-goal-manage-row-#{goal.id} button", "Assign")
      |> render_click()

      assert has_element?(form_live, "[data-member-goals] #target-goal-manage-row-#{goal.id}")

      refute has_element?(
               form_live,
               "[data-assignable-goals] #target-goal-manage-row-#{goal.id}"
             )

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

      assert has_element?(form_live, "[data-member-goals] #target-goal-manage-row-#{goal.id}")

      form_live
      |> element("[data-member-goals] #target-goal-manage-row-#{goal.id} button", "Unassign")
      |> render_click()

      assert has_element?(
               form_live,
               "[data-assignable-goals] #target-goal-manage-row-#{goal.id}"
             )

      refute has_element?(form_live, "[data-member-goals] #target-goal-manage-row-#{goal.id}")
      assert Targets.list_member_goals(scope, target) == []
    end

    test "renders each goal row with a progress count and owner cell", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Ship API"})
      # one incomplete + one complete child => 1 of 2 (50%)
      task_fixture(column, %{parent_id: goal.id})
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, form_live, html} = live(conn, ~p"/targets/#{target}/edit")

      # Progress count cell rendered by TargetGoalManageRow.
      assert html =~ "1 of 2 (50%)"

      assert has_element?(
               form_live,
               "[data-member-goals] #target-goal-manage-row-#{goal.id} [data-goal-col='progress']"
             )

      # Owner cell rendered; this goal has no assignee, so it reads "unassigned".
      assert has_element?(
               form_live,
               "[data-member-goals] #target-goal-manage-row-#{goal.id} [data-goal-col='owner']"
             )

      assert html =~ "unassigned"
    end
  end

  defp complete_task(task) do
    {:ok, done} =
      task
      |> Kanban.Tasks.Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()

    done
  end

  describe "anonymous" do
    test "the new form redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/targets/new")
      assert to =~ "/users/log-in"
    end

    test "the edit form redirects to the login page", %{conn: conn} do
      user = user_fixture()
      target = delivery_target_fixture(user)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/targets/#{target}/edit")
      assert to =~ "/users/log-in"
    end
  end
end
