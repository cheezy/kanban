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
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  defp goal_fixture(column, attrs) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  # Creates a goal, then force-stamps a specific identifier (e.g. "G131") so a
  # test can assert numeric-vs-alphabetical render order. `identifier` is
  # server-injected and not castable, so set it directly via
  # `Ecto.Changeset.change/2`, which bypasses the cast allow-list.
  defp goal_with_identifier(column, identifier, attrs) do
    column
    |> goal_fixture(attrs)
    |> Ecto.Changeset.change(identifier: identifier)
    |> Repo.update!()
  end

  defp complete_task(task) do
    {:ok, done} =
      task
      |> Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()

    done
  end

  # A target whose single member goal is complete — the only state that derives
  # :complete, and therefore the only state that renders the Archive action.
  defp complete_target(scope, user, column) do
    target = delivery_target_fixture(user)
    goal = column |> goal_fixture(%{title: "Delivered Goal"}) |> complete_task()
    assert {:ok, _} = Targets.assign_goal(scope, goal, target)

    target
  end

  defp count_occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {start, _len} -> start
      :nomatch -> -1
    end
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

    test "renders the goals table rows in ascending numeric identifier order",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      g131 = goal_with_identifier(column, "G131", %{title: "Goal 131"})
      g18 = goal_with_identifier(column, "G18", %{title: "Goal 18"})
      g9 = goal_with_identifier(column, "G9", %{title: "Goal 9"})

      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      for goal <- [g131, g18, g9], do: assert({:ok, _} = Targets.assign_goal(scope, goal, target))

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      # Identifiers must appear in numeric (not alphabetical) order in the markup.
      positions = Enum.map(["G9", "G18", "G131"], &index_of(html, &1))
      assert positions == Enum.sort(positions)
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

    test "renders an archived-but-finished goal as complete (100%), not understated (D124)",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = goal_fixture(column, %{title: "Shipped and archived"})
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Scope.for_user(user)
      assert {:ok, goal} = Targets.assign_goal(scope, goal, target)
      # Archiving cascades to the completed child and collapses the old view to
      # 0/0 — after the fix it must still read complete.
      {:ok, _} = Kanban.Tasks.archive_task(goal)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "Shipped and archived"
      assert html =~ "1 of 1 complete"
      assert html =~ "100%"
    end

    test "shows agent attribution in the owner column for an agent-completed, unassigned goal (D132)",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      goal =
        goal_fixture(column, %{
          title: "Agent-built goal",
          completed_by_agent: "Claude Sonnet 4.5"
        })

      target = delivery_target_fixture(user)
      scope = Scope.for_user(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/#{target}")

      assert html =~ "data-target-goal-row"
      assert html =~ "Claude Sonnet 4.5"
      refute html =~ "unassigned"
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

  describe "archive_target event" do
    setup [:register_and_log_in_user]

    test "renders the Archive button with a confirm prompt for a :complete target",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = complete_target(Scope.for_user(user), user, column)

      {:ok, live, html} = live(conn, ~p"/targets/#{target}")

      assert has_element?(live, "[data-archive-target]")
      assert html =~ "Archive target"
      # data-confirm gates the click browser-side. LiveViewTest cannot drive the
      # browser dialog, so the attribute's presence is the assertable proof —
      # the context re-checks regardless.
      assert html =~ "data-confirm"
      assert html =~ "Archive this target?"
    end

    test "does not render the Archive button for an incomplete (:on_track) target",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      scope = Scope.for_user(user)
      goal = goal_fixture(column, %{title: "Still Going"})
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, live, html} = live(conn, ~p"/targets/#{target}")

      refute has_element?(live, "[data-archive-target]")
      refute html =~ "Archive target"
    end

    test "does not render the Archive button for a memberless target, which derives :on_track",
         %{conn: conn, user: user} do
      target = delivery_target_fixture(user, %{name: "Empty Target"})

      {:ok, live, _html} = live(conn, ~p"/targets/#{target}")

      refute has_element?(live, "[data-archive-target]")
    end

    test "does not render the Archive button for a :missed target", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      scope = Scope.for_user(user)
      goal = goal_fixture(column, %{title: "Late Goal"})
      target = delivery_target_fixture(user, %{target_date: ~D[2020-01-01]})
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, live, _html} = live(conn, ~p"/targets/#{target}")

      refute has_element?(live, "[data-archive-target]")
    end

    test "archiving a complete target flashes success, stamps archived_at and navigates to /boards",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = complete_target(Scope.for_user(user), user, column)

      {:ok, live, _html} = live(conn, ~p"/targets/#{target}")

      # Driven through the real button, so this also proves the markup wires
      # phx-click correctly.
      live |> element("[data-archive-target]") |> render_click()
      flash = assert_redirect(live, ~p"/boards")

      assert flash["info"] =~ "Target archived successfully"
      assert %DateTime{} = Repo.get!(DeliveryTarget, target.id).archived_at
    end

    test "archiving an incomplete target is refused by the context and stays on the page",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      scope = Scope.for_user(user)
      goal = goal_fixture(column, %{title: "Still Going"})
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, live, _html} = live(conn, ~p"/targets/#{target}")

      # Fired directly: the button never renders in this state, so this proves
      # the context re-checks completeness rather than trusting the hidden
      # button.
      html = render_click(live, "archive_target", %{})

      assert html =~ "Only a complete target can be archived"
      assert render(live) =~ "Still Going"
      assert Repo.get!(DeliveryTarget, target.id).archived_at == nil
    end

    test "archiving a target that vanished after mount flashes not-found and navigates to /boards",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = complete_target(Scope.for_user(user), user, column)

      {:ok, live, _html} = live(conn, ~p"/targets/#{target}")

      # The target is deleted in another session between mount and click.
      # tasks.target_id is ON DELETE nilify_all, so the member goal survives.
      Repo.delete!(target)

      render_click(live, "archive_target", %{})
      flash = assert_redirect(live, ~p"/boards")

      assert flash["error"] =~ "Target not found"
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
