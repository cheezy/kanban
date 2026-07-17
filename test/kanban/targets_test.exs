defmodule Kanban.TargetsTest do
  @moduledoc """
  Tests for `Kanban.Targets` — board-scoped CRUD and goal membership for
  delivery targets. Visibility flows through accessible member goals, so the
  scoping assertions build a second user/board and assert cross-board denial.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    scope = Scope.for_user(user)

    # A second, unrelated user + board the first user cannot access.
    other_user = user_fixture()
    other_board = board_fixture(other_user)
    other_column = column_fixture(other_board)
    other_scope = Scope.for_user(other_user)

    %{
      user: user,
      board: board,
      column: column,
      scope: scope,
      other_user: other_user,
      other_board: other_board,
      other_column: other_column,
      other_scope: other_scope
    }
  end

  defp goal_fixture(column, attrs \\ %{}) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  # Creates a goal, then force-stamps a specific identifier (e.g. "G131") so a
  # test can exercise the case where alphabetical and numeric order diverge.
  # `identifier` is server-injected and not castable, so we set it directly via
  # `Ecto.Changeset.change/2`, which bypasses the cast allow-list.
  defp goal_with_identifier(column, identifier, attrs \\ %{}) do
    column
    |> goal_fixture(attrs)
    |> Ecto.Changeset.change(identifier: identifier)
    |> Repo.update!()
  end

  # A target whose single member goal is complete — the minimal shape
  # `Status.derive/3` reads as `:complete` (all_complete?/1 trusts the goal's
  # stored status; a childless completed goal needs no children).
  defp complete_target(scope, column, user) do
    target = delivery_target_fixture(user)
    goal = column |> goal_fixture() |> complete_task()
    assert {:ok, _} = Targets.assign_goal(scope, goal, target)

    target
  end

  # Force-stamps archived_at so ordering assertions never race the clock.
  # archived_at is only castable via archive_changeset/2, so this bypasses the
  # allow-list the same way goal_with_identifier/3 does.
  defp archived_at!(target, at) do
    target
    |> Ecto.Changeset.change(archived_at: at)
    |> Repo.update!()
  end

  describe "create_target/2" do
    test "creates a target and stamps owner_id from the scope", %{scope: scope, user: user} do
      assert {:ok, %DeliveryTarget{} = target} =
               Targets.create_target(scope, %{name: "Q3 Launch", target_date: ~D[2026-09-30]})

      assert target.owner_id == user.id
      assert target.name == "Q3 Launch"
    end

    test "ignores a client-supplied owner_id (not castable)", %{
      scope: scope,
      user: user,
      other_user: other
    } do
      assert {:ok, target} =
               Targets.create_target(scope, %{
                 name: "Forged",
                 target_date: ~D[2026-09-30],
                 owner_id: other.id
               })

      assert target.owner_id == user.id
    end

    test "returns a changeset error when required fields are missing", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = cs} = Targets.create_target(scope, %{name: "No date"})
      assert %{target_date: ["can't be blank"]} = errors_on(cs)
    end

    test "returns {:error, :not_authorized} for a nil scope" do
      assert {:error, :not_authorized} =
               Targets.create_target(nil, %{name: "X", target_date: ~D[2026-09-30]})
    end
  end

  describe "update_target/3" do
    test "updates editable fields", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:ok, updated} =
               Targets.update_target(scope, target, %{name: "Renamed", description: "why"})

      assert updated.name == "Renamed"
      assert updated.description == "why"
    end

    test "returns a changeset error on invalid data", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:error, %Ecto.Changeset{}} = Targets.update_target(scope, target, %{name: nil})
    end

    test "returns {:error, :not_authorized} for a nil scope", %{user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_authorized} = Targets.update_target(nil, target, %{name: "Nope"})
    end
  end

  describe "list_targets/1" do
    test "returns targets with a member goal on an accessible board", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [listed] = Targets.list_targets(scope)
      assert listed.id == target.id
    end

    test "excludes targets whose only goals are on an inaccessible board", %{
      user: user,
      other_scope: other_scope,
      column: column,
      scope: scope
    } do
      # Target's single member goal lives on `user`'s board.
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      # The second user cannot see it — its goal is on an inaccessible board.
      assert Targets.list_targets(other_scope) == []
    end

    test "excludes targets that have no member goals", %{scope: scope, user: user} do
      _target = delivery_target_fixture(user)
      assert Targets.list_targets(scope) == []
    end

    test "excludes archived targets but keeps active ones", %{
      scope: scope,
      user: user,
      column: column
    } do
      archived = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, archived.id)

      active = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_fixture(column), active)

      assert [listed] = Targets.list_targets(scope)
      assert listed.id == active.id
    end
  end

  describe "archive_target/2" do
    test "archives a complete target", %{scope: scope, user: user, column: column} do
      target = complete_target(scope, column, user)

      assert {:ok, %DeliveryTarget{} = archived} = Targets.archive_target(scope, target.id)
      assert %DateTime{} = archived.archived_at
    end

    test "returns {:error, :not_complete} when a member goal is incomplete", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_fixture(column), target)

      assert {:error, :not_complete} = Targets.archive_target(scope, target.id)
      assert Repo.get!(DeliveryTarget, target.id).archived_at == nil
    end

    test "returns {:error, :not_complete} when a target has no member goals", %{
      scope: scope,
      user: user
    } do
      # Status.derive/3 reads an empty goal list as :on_track, never a vacuous
      # :complete — an empty target has delivered nothing, so it cannot archive.
      target = delivery_target_fixture(user)

      assert {:error, :not_complete} = Targets.archive_target(scope, target.id)
    end

    test "returns {:error, :not_complete} when only some member goals are complete", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)

      assert {:ok, _} =
               Targets.assign_goal(scope, column |> goal_fixture() |> complete_task(), target)

      assert {:ok, _} = Targets.assign_goal(scope, goal_fixture(column), target)

      assert {:error, :not_complete} = Targets.archive_target(scope, target.id)
    end

    test "returns {:error, :not_found} for a nonexistent target", %{scope: scope} do
      assert {:error, :not_found} = Targets.archive_target(scope, -1)
    end

    test "returns {:error, :not_found} when the caller does not own the target", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope
    } do
      target = complete_target(scope, column, user)

      # Ownership is checked before completeness, so a non-owner cannot tell
      # "exists but incomplete" from "does not exist".
      assert {:error, :not_found} = Targets.archive_target(other_scope, target.id)
      assert Repo.get!(DeliveryTarget, target.id).archived_at == nil
    end

    test "returns {:error, :not_found} for a nil scope", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = complete_target(scope, column, user)

      assert {:error, :not_found} = Targets.archive_target(nil, target.id)
    end
  end

  describe "unarchive_target/2" do
    test "clears archived_at for the owner", %{scope: scope, user: user, column: column} do
      target = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, target.id)

      assert {:ok, %DeliveryTarget{} = unarchived} = Targets.unarchive_target(scope, target.id)
      assert unarchived.archived_at == nil
    end

    test "restores the target to list_targets/1", %{scope: scope, user: user, column: column} do
      target = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, target.id)
      assert Targets.list_targets(scope) == []

      assert {:ok, _} = Targets.unarchive_target(scope, target.id)
      assert [listed] = Targets.list_targets(scope)
      assert listed.id == target.id
    end

    test "unarchives a target that is no longer complete", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, target.id)

      # A newly assigned incomplete goal drops the target out of :complete —
      # unarchiving is not gated on completeness, so it must still recover.
      assert {:ok, _} = Targets.assign_goal(scope, goal_fixture(column), target)

      assert {:ok, unarchived} = Targets.unarchive_target(scope, target.id)
      assert unarchived.archived_at == nil
    end

    test "returns {:error, :not_found} when the caller does not own the target", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope
    } do
      target = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, target.id)

      assert {:error, :not_found} = Targets.unarchive_target(other_scope, target.id)
      assert Repo.get!(DeliveryTarget, target.id).archived_at != nil
    end

    test "returns {:error, :not_found} for a nil scope", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = complete_target(scope, column, user)

      assert {:error, :not_found} = Targets.unarchive_target(nil, target.id)
    end
  end

  describe "list_archived_targets/1" do
    test "returns only archived targets", %{scope: scope, user: user, column: column} do
      archived = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, archived.id)

      active = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_fixture(column), active)

      assert [listed] = Targets.list_archived_targets(scope)
      assert listed.id == archived.id
    end

    test "orders newest archived first", %{scope: scope, user: user, column: column} do
      oldest = complete_target(scope, column, user)
      middle = complete_target(scope, column, user)
      newest = complete_target(scope, column, user)

      for {target, at} <- [
            {oldest, ~U[2026-01-01 00:00:00.000000Z]},
            {middle, ~U[2026-03-01 00:00:00.000000Z]},
            {newest, ~U[2026-06-01 00:00:00.000000Z]}
          ] do
        archived_at!(target, at)
      end

      assert [first, second, third] = Targets.list_archived_targets(scope)
      assert [first.id, second.id, third.id] == [newest.id, middle.id, oldest.id]
    end

    test "excludes archived targets whose goals are on an inaccessible board", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope
    } do
      target = complete_target(scope, column, user)
      assert {:ok, _} = Targets.archive_target(scope, target.id)

      # Same board-scoped visibility model as list_targets/1.
      assert Targets.list_archived_targets(other_scope) == []
    end

    test "returns [] when nothing is archived", %{scope: scope, user: user, column: column} do
      _active = complete_target(scope, column, user)

      assert Targets.list_archived_targets(scope) == []
    end
  end

  describe "get_target/2" do
    test "returns {:ok, target} when reachable via an accessible member goal", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:ok, fetched} = Targets.get_target(scope, target.id)
      assert fetched.id == target.id
    end

    test "returns {:error, :not_found} when the only member goal is on an inaccessible board", %{
      user: user,
      column: column,
      scope: scope,
      other_scope: other_scope
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:error, :not_found} = Targets.get_target(other_scope, target.id)
    end

    test "returns {:error, :not_found} for a target with no member goals", %{
      scope: scope,
      user: user
    } do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_target(scope, target.id)
    end
  end

  describe "assign_goal/3" do
    test "sets target_id on a goal on an accessible board", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)

      assert {:ok, assigned} = Targets.assign_goal(scope, goal, target)
      assert assigned.target_id == target.id
    end

    test "rejects a non-goal (work) task with a changeset error", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      work = task_fixture(column, %{type: :work})

      assert {:error, %Ecto.Changeset{} = cs} = Targets.assign_goal(scope, work, target)
      assert %{target_id: ["may only be set on goal-type tasks"]} = errors_on(cs)
    end

    test "rejects a goal on an inaccessible board with {:error, :not_found}", %{
      scope: scope,
      user: user,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)
      foreign_goal = goal_fixture(other_column)

      assert {:error, :not_found} = Targets.assign_goal(scope, foreign_goal, target)

      # And nothing was written.
      assert Repo.get!(Task, foreign_goal.id).target_id == nil
    end

    test "rejects a read-only member of the goal's board even if they own the target", %{
      user: owner,
      board: board,
      column: column
    } do
      goal = goal_fixture(column)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      reader_target = delivery_target_fixture(reader)
      reader_scope = Scope.for_user(reader)

      assert {:error, :not_authorized} =
               Targets.assign_goal(reader_scope, goal, reader_target)

      # Nothing was written.
      assert Repo.get!(Task, goal.id).target_id == nil
    end

    test "allows a :modify member of the goal's board who owns the target", %{
      user: owner,
      board: board,
      column: column
    } do
      goal = goal_fixture(column)
      modifier = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
      modifier_target = delivery_target_fixture(modifier)
      modifier_scope = Scope.for_user(modifier)

      assert {:ok, assigned} =
               Targets.assign_goal(modifier_scope, goal, modifier_target)

      assert assigned.target_id == modifier_target.id
    end
  end

  describe "unassign_goal/2" do
    test "clears the target reference on an accessible goal", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert {:ok, unassigned} = Targets.unassign_goal(scope, goal)
      assert unassigned.target_id == nil
      assert Repo.get!(Task, goal.id).target_id == nil
    end

    test "returns {:error, :not_found} for a goal on an inaccessible board", %{
      other_column: other_column,
      scope: scope
    } do
      foreign_goal = goal_fixture(other_column)
      assert {:error, :not_found} = Targets.unassign_goal(scope, foreign_goal)
    end

    test "rejects a read-only member of the goal's board and leaves target_id intact", %{
      user: owner,
      board: board,
      column: column,
      scope: owner_scope
    } do
      goal = goal_fixture(column)
      target = delivery_target_fixture(owner)
      assert {:ok, _} = Targets.assign_goal(owner_scope, goal, target)

      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      reader_scope = Scope.for_user(reader)

      assert {:error, :not_authorized} = Targets.unassign_goal(reader_scope, goal)

      # The existing linkage is untouched.
      assert Repo.get!(Task, goal.id).target_id == target.id
    end
  end

  describe "list_member_goals/2" do
    test "returns only member goals on accessible boards", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)

      accessible_goal = goal_fixture(column)
      foreign_goal = goal_fixture(other_column)

      assert {:ok, _} = Targets.assign_goal(scope, accessible_goal, target)
      assert {:ok, _} = Targets.assign_goal(other_scope, foreign_goal, target)

      ids = scope |> Targets.list_member_goals(target) |> Enum.map(& &1.id)
      assert ids == [accessible_goal.id]

      other_ids = other_scope |> Targets.list_member_goals(target) |> Enum.map(& &1.id)
      assert other_ids == [foreign_goal.id]
    end

    test "orders goals by numeric identifier so G18 precedes G131", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)

      g131 = goal_with_identifier(column, "G131")
      g18 = goal_with_identifier(column, "G18")
      g9 = goal_with_identifier(column, "G9")

      for goal <- [g131, g18, g9], do: assert({:ok, _} = Targets.assign_goal(scope, goal, target))

      identifiers = scope |> Targets.list_member_goals(target) |> Enum.map(& &1.identifier)
      assert identifiers == ["G9", "G18", "G131"]
    end

    test "breaks identifier-number ties deterministically by id ascending", %{
      scope: scope,
      user: user,
      board: board
    } do
      target = delivery_target_fixture(user)

      # Identifier numbers are per-board, so two goals can share "G5"; the sort
      # must still be total. Force-stamp the same identifier on two goals.
      column_a = column_fixture(board)
      column_b = column_fixture(board)
      first = goal_with_identifier(column_a, "G5")
      second = goal_with_identifier(column_b, "G5")

      for goal <- [second, first],
          do: assert({:ok, _} = Targets.assign_goal(scope, goal, target))

      ids = scope |> Targets.list_member_goals(target) |> Enum.map(& &1.id)
      assert ids == Enum.sort([first.id, second.id])
    end
  end

  describe "full create -> assign -> list-members -> unassign cycle" do
    test "walks the target lifecycle end to end", %{scope: scope, column: column} do
      assert {:ok, target} =
               Targets.create_target(scope, %{name: "Cycle", target_date: ~D[2026-11-01]})

      # Not visible until it has a member goal.
      assert Targets.list_targets(scope) == []
      assert {:error, :not_found} = Targets.get_target(scope, target.id)

      goal = goal_fixture(column)
      assert {:ok, assigned} = Targets.assign_goal(scope, goal, target)
      assert assigned.target_id == target.id

      # Now visible.
      assert [listed] = Targets.list_targets(scope)
      assert listed.id == target.id
      assert {:ok, _} = Targets.get_target(scope, target.id)

      assert [member] = Targets.list_member_goals(scope, target)
      assert member.id == goal.id

      assert {:ok, unassigned} = Targets.unassign_goal(scope, goal)
      assert unassigned.target_id == nil

      # Back to invisible with no member goals.
      assert Targets.list_member_goals(scope, target) == []
      assert Targets.list_targets(scope) == []
    end
  end

  describe "list_targets_with_status/2" do
    test "summarizes a target with aggregate child progress and a derived status",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      _incomplete = task_fixture(column, %{parent_id: goal.id})
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      # today early in the target's window (created ~now, target_date 2026-12-31)
      # with work at 1/2 = 0.5 => work leads elapsed => :on_track.
      assert [summary] = Targets.list_targets_with_status(scope, ~D[2026-07-07])

      assert summary.target.id == target.id
      assert summary.completed == 1
      assert summary.total == 2
      assert summary.percentage == 50
      assert summary.status == :on_track
    end

    test "no longer includes a target once it is archived",
         %{scope: scope, user: user, column: column} do
      target = complete_target(scope, column, user)

      assert [summary] = Targets.list_targets_with_status(scope, ~D[2026-07-07])
      assert summary.target.id == target.id
      assert summary.status == :complete

      assert {:ok, _} = Targets.archive_target(scope, target.id)

      # The boards feed is built on list_targets/1, so the is_nil filter there
      # is what removes an archived target from the boards page.
      assert Targets.list_targets_with_status(scope, ~D[2026-07-07]) == []
    end

    test "reports 0/0 (0%) progress when a member goal has no children",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, ~D[2026-07-07])
      assert summary.completed == 0
      assert summary.total == 0
      assert summary.percentage == 0
    end

    test "excludes targets whose goals are all on inaccessible boards",
         %{scope: scope, user: user, column: column, other_scope: other_scope} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert Targets.list_targets_with_status(other_scope, ~D[2026-07-07]) == []
    end
  end

  @estimate_today ~D[2026-07-07]

  # A completed historical (non-child) task with an EXACT lead time of
  # `days`, both timestamps pinned so assertions never depend on the wall
  # clock. inserted_at is not castable to the past through the changeset, so
  # this bypasses the cast allow-list the same way goal_with_identifier/3
  # does.
  defp completed_with_lead(column, days) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(
      status: :completed,
      completed_at: ~U[2026-07-01 12:00:00Z],
      inserted_at: NaiveDateTime.add(~N[2026-07-01 12:00:00], -days * 86_400)
    )
    |> Repo.update!()
  end

  # A target with one member goal carrying `remaining` incomplete children.
  defp target_with_remaining(scope, column, user, remaining) do
    goal = goal_fixture(column)
    for _ <- 1..remaining, do: task_fixture(column, %{parent_id: goal.id})
    target = delivery_target_fixture(user)
    assert {:ok, _} = Targets.assign_goal(scope, goal, target)

    target
  end

  describe "list_targets_with_status/2 — estimated_completion_date" do
    test "projects today + remaining * p50 lead time from board history",
         %{scope: scope, user: user, column: column} do
      # Historical leads of 1/2/4 days -> p50 = 2.0 days; 2 remaining
      # children -> 4.0 days -> today + 4.
      for days <- [1, 2, 4], do: completed_with_lead(column, days)
      target_with_remaining(scope, column, user, 2)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 4)
    end

    test "is nil when there are no historical completed tasks",
         %{scope: scope, user: user, column: column} do
      target_with_remaining(scope, column, user, 2)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.estimated_completion_date == nil
    end

    test "ignores completed goal-type tasks in the historical sample",
         %{scope: scope, user: user, column: column} do
      column |> goal_fixture() |> complete_task()
      target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.estimated_completion_date == nil
    end

    test "ignores history on boards not backing the target's member goals",
         %{scope: scope, user: user, column: column, other_column: other_column} do
      completed_with_lead(other_column, 3)
      target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.estimated_completion_date == nil
    end

    test "uses all-time history, not a trailing window",
         %{scope: scope, user: user, column: column} do
      # Completed ~18 months before `today` with a 2-day lead — far outside
      # any 30/90-day metrics window, but still the pace sample here.
      column
      |> task_fixture()
      |> Ecto.Changeset.change(
        status: :completed,
        completed_at: ~U[2025-01-01 12:00:00Z],
        inserted_at: ~N[2024-12-30 12:00:00]
      )
      |> Repo.update!()

      target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 2)
    end

    test "is nil for a :complete target even with history present",
         %{scope: scope, user: user, column: column} do
      completed_with_lead(column, 2)
      complete_target(scope, column, user)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.status == :complete
      assert summary.estimated_completion_date == nil
    end

    test "is nil when nothing remains (childless 0/0 goal) even with history",
         %{scope: scope, user: user, column: column} do
      completed_with_lead(column, 2)
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_today)
      assert summary.status == :on_track
      assert summary.total == 0
      assert summary.estimated_completion_date == nil
    end

    test "the rollup and drill-down paths do not estimate",
         %{scope: scope, user: user, column: column} do
      for days <- [1, 2, 4], do: completed_with_lead(column, days)
      target = target_with_remaining(scope, column, user, 2)

      assert [with_goals] =
               Targets.list_targets_with_status_and_goals(scope, @estimate_today)

      assert with_goals.estimated_completion_date == nil

      assert %{summary: summary} =
               Targets.get_target_progress(scope, target, @estimate_today)

      assert summary.estimated_completion_date == nil
    end
  end

  describe "get_target_progress/3" do
    test "aggregate summary matches list_targets_with_status/2 for the same target",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      _incomplete = task_fixture(column, %{parent_id: goal.id})
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      [expected] = Targets.list_targets_with_status(scope, ~D[2026-07-07])
      assert %{summary: summary} = Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert summary.target.id == target.id
      assert summary.status == expected.status
      assert summary.completed == expected.completed
      assert summary.total == expected.total
      assert summary.percentage == expected.percentage
    end

    test "returns a per-goal entry whose flow buckets children by column name",
         %{scope: scope, user: user, board: board, column: column} do
      goal = goal_fixture(column)

      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})
      done = column_fixture(board, %{name: "Done"})

      task_fixture(backlog, %{parent_id: goal.id})
      task_fixture(ready, %{parent_id: goal.id})
      task_fixture(doing, %{parent_id: goal.id})
      task_fixture(review, %{parent_id: goal.id})
      complete_task(task_fixture(done, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{goals: [entry]} = Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert entry.goal.id == goal.id
      assert entry.flow == %{backlog: 1, ready: 1, doing: 1, review: 1, done: 1, total: 5}
      assert entry.completed == 1
      assert entry.total == 5
      assert entry.percentage == 20
    end

    test "flow buckets by column name even when a child's status disagrees",
         %{scope: scope, user: user, board: board, column: column} do
      goal = goal_fixture(column)
      ready = column_fixture(board, %{name: "Ready"})
      # Completed (status) but sitting in the Ready column: it must bucket to
      # :ready (column) yet still count toward :completed (status).
      complete_task(task_fixture(ready, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{goals: [entry]} = Targets.get_target_progress(scope, target, ~D[2026-07-07])
      assert entry.flow == %{backlog: 0, ready: 1, doing: 0, review: 0, done: 0, total: 1}
      assert entry.completed == 1
      assert entry.total == 1
    end

    test "a member goal with no children yields an all-zero flow map",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{goals: [entry]} = Targets.get_target_progress(scope, target, ~D[2026-07-07])
      assert entry.flow == %{backlog: 0, ready: 0, doing: 0, review: 0, done: 0, total: 0}
      assert entry.completed == 0
      assert entry.total == 0
      assert entry.percentage == 0
    end

    test "counts a Ready-column member goal's non-archived, not-yet-started children (D129 regression)",
         %{scope: scope, user: user, board: board} do
      # Regression for D129: a goal sitting in Ready whose children are all
      # non-archived and not yet started (open/blocked) must still count as
      # 0 of N — never 0 of 0. Mirrors production goal G323 (child W1665 open,
      # W1666/W1667 blocked, all in the Ready column). The count credits every
      # non-archived child regardless of its column or not-started status.
      ready = column_fixture(board, %{name: "Ready"})
      goal = goal_fixture(ready)

      _open_child = task_fixture(ready, %{parent_id: goal.id})
      blocked_a = task_fixture(ready, %{parent_id: goal.id})
      blocked_b = task_fixture(ready, %{parent_id: goal.id})
      assert {:ok, %{status: :blocked}} = Kanban.Tasks.update_task(blocked_a, %{status: :blocked})
      assert {:ok, %{status: :blocked}} = Kanban.Tasks.update_task(blocked_b, %{status: :blocked})

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      # Assigning the goal makes it a member of the target (association drives
      # visibility) — an unassigned goal would be absent and the target 0/0.
      assert [member] = Targets.list_member_goals(scope, target)
      assert member.id == goal.id

      # Its three active children are counted: the target reports 0 of 3, not 0 of 0.
      assert %{summary: summary, goals: [entry]} =
               Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert summary.completed == 0
      assert summary.total == 3
      assert entry.goal.id == goal.id
      assert entry.completed == 0
      assert entry.total == 3
    end

    test "a target with no member goals returns a zeroed summary and empty goals",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)

      assert %{summary: summary, goals: []} =
               Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert summary.target.id == target.id
      assert summary.completed == 0
      assert summary.total == 0
      assert summary.percentage == 0
      assert summary.status == :on_track
    end

    test "a fully-complete target reports 100% and :complete status",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      complete_task(goal)

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{summary: summary, goals: [entry]} =
               Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert summary.completed == 2
      assert summary.total == 2
      assert summary.percentage == 100
      assert summary.status == :complete
      assert entry.percentage == 100
    end

    test "aggregates completed/total across multiple member goals",
         %{scope: scope, user: user, column: column} do
      goal_a = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal_a.id}))
      _a_incomplete = task_fixture(column, %{parent_id: goal_a.id})

      goal_b = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal_b.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal_a, target)
      assert {:ok, _} = Targets.assign_goal(scope, goal_b, target)

      assert %{summary: summary, goals: goals} =
               Targets.get_target_progress(scope, target, ~D[2026-07-07])

      assert summary.completed == 2
      assert summary.total == 3
      assert summary.percentage == 67
      assert length(goals) == 2
    end

    test "is board-scoped: a foreign scope sees none of the target's member goals",
         %{scope: scope, user: user, column: column, other_scope: other_scope} do
      goal = goal_fixture(column)
      task_fixture(column, %{parent_id: goal.id})
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{summary: summary, goals: []} =
               Targets.get_target_progress(other_scope, target, ~D[2026-07-07])

      assert summary.total == 0
    end

    test "accepts a target id, resolving it through the board-scoped get_target/2",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      by_struct = Targets.get_target_progress(scope, target, ~D[2026-07-07])
      by_id = Targets.get_target_progress(scope, target.id, ~D[2026-07-07])

      assert by_id.summary.target.id == target.id
      assert by_id.summary.completed == by_struct.summary.completed
      assert by_id.summary.total == by_struct.summary.total
      assert by_id.summary.percentage == by_struct.summary.percentage
      assert length(by_id.goals) == length(by_struct.goals)
    end

    test "returns {:error, :not_found} for an id with no accessible target",
         %{scope: scope} do
      assert {:error, :not_found} = Targets.get_target_progress(scope, 999_999_999)
    end

    test "returns {:error, :not_found} for a memberless target referenced by id",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_target_progress(scope, target.id)
    end
  end

  describe "owner?/2" do
    test "true for the owner, false for a non-owner", %{user: user, other_user: other} do
      target = delivery_target_fixture(user)
      assert Targets.owner?(target, user)
      refute Targets.owner?(target, other)
    end
  end

  describe "change_target/2" do
    test "returns a changeset for the target", %{user: user} do
      target = delivery_target_fixture(user)
      assert %Ecto.Changeset{} = Targets.change_target(target)
    end

    test "does not cast owner_id (never mass-assignable)", %{user: user, other_user: other} do
      target = delivery_target_fixture(user)
      cs = Targets.change_target(target, %{owner_id: other.id})
      refute Map.has_key?(cs.changes, :owner_id)
    end
  end

  describe "get_owned_target/2" do
    test "returns {:ok, target} with :owner preloaded for the owner (no goals needed)",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:ok, fetched} = Targets.get_owned_target(scope, target.id)
      assert fetched.id == target.id
      assert fetched.owner.id == user.id
    end

    test "returns {:error, :not_found} for a target owned by another user",
         %{other_scope: other_scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_owned_target(other_scope, target.id)
    end

    test "returns {:error, :not_found} for a missing id", %{scope: scope} do
      assert {:error, :not_found} = Targets.get_owned_target(scope, 999_999_999)
    end

    test "returns {:error, :not_found} for a nil scope", %{user: user} do
      target = delivery_target_fixture(user)
      assert {:error, :not_found} = Targets.get_owned_target(nil, target.id)
    end
  end

  describe "update_target/3 authorization" do
    test "the owner may update", %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert {:ok, updated} = Targets.update_target(scope, target, %{name: "Owner Renamed"})
      assert updated.name == "Owner Renamed"
    end

    test "a non-owner is rejected with {:error, :not_authorized}",
         %{other_scope: other_scope, user: user} do
      target = delivery_target_fixture(user)

      assert {:error, :not_authorized} =
               Targets.update_target(other_scope, target, %{name: "Nope"})

      assert Repo.get!(DeliveryTarget, target.id).name == target.name
    end
  end

  describe "list_assignable_goals/2" do
    test "returns goals not on this target, on accessible boards",
         %{scope: scope, user: user, column: column, other_column: other_column} do
      target = delivery_target_fixture(user)

      unassigned = goal_fixture(column)
      already_here = goal_fixture(column)
      foreign = goal_fixture(other_column)
      assert {:ok, _} = Targets.assign_goal(scope, already_here, target)

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)

      assert unassigned.id in ids
      refute already_here.id in ids
      refute foreign.id in ids
    end

    test "excludes goals already assigned to a different target (no silent stealing)",
         %{scope: scope, user: user, column: column} do
      target = delivery_target_fixture(user)
      other_target = delivery_target_fixture(user)

      goal = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, goal, other_target)

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)
      refute goal.id in ids
    end

    test "excludes non-goal (work) tasks", %{scope: scope, user: user, column: column} do
      target = delivery_target_fixture(user)
      work = task_fixture(column, %{type: :work})

      ids = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.id)
      refute work.id in ids
    end

    test "orders candidates by numeric identifier so G18 precedes G131", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)

      goal_with_identifier(column, "G131")
      goal_with_identifier(column, "G18")
      goal_with_identifier(column, "G9")

      identifiers = scope |> Targets.list_assignable_goals(target) |> Enum.map(& &1.identifier)
      assert identifiers == ["G9", "G18", "G131"]
    end
  end

  describe "list_member_goal_details/2" do
    test "returns one goal_progress_detail per member goal with flow and fraction",
         %{scope: scope, user: user, board: board, column: column} do
      goal = goal_fixture(column)

      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})
      done = column_fixture(board, %{name: "Done"})

      task_fixture(backlog, %{parent_id: goal.id})
      task_fixture(ready, %{parent_id: goal.id})
      task_fixture(doing, %{parent_id: goal.id})
      task_fixture(review, %{parent_id: goal.id})
      complete_task(task_fixture(done, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [entry] = Targets.list_member_goal_details(scope, target)

      assert Map.keys(entry) |> Enum.sort() ==
               [:completed, :flow, :goal, :percentage, :total]

      assert entry.goal.id == goal.id
      assert entry.flow == %{backlog: 1, ready: 1, doing: 1, review: 1, done: 1, total: 5}
      assert entry.completed == 1
      assert entry.total == 5
      assert entry.percentage == 20
    end

    test "each returned goal has :column and :assigned_to preloaded",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [entry] = Targets.list_member_goal_details(scope, target)
      assert Ecto.assoc_loaded?(entry.goal.column)
      assert Ecto.assoc_loaded?(entry.goal.assigned_to)
    end

    test "a childless member goal yields an all-zero flow map",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [entry] = Targets.list_member_goal_details(scope, target)
      assert entry.flow == %{backlog: 0, ready: 0, doing: 0, review: 0, done: 0, total: 0}
      assert entry.completed == 0
      assert entry.total == 0
      assert entry.percentage == 0
    end

    test "excludes member goals on boards the scope cannot access", %{
      scope: scope,
      user: user,
      column: column,
      other_scope: other_scope,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)

      accessible_goal = goal_fixture(column)
      foreign_goal = goal_fixture(other_column)
      assert {:ok, _} = Targets.assign_goal(scope, accessible_goal, target)
      assert {:ok, _} = Targets.assign_goal(other_scope, foreign_goal, target)

      ids = scope |> Targets.list_member_goal_details(target) |> Enum.map(& &1.goal.id)
      assert ids == [accessible_goal.id]
    end

    test "returns [] when the target has no member goals",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert Targets.list_member_goal_details(scope, target) == []
    end

    test "orders detail entries by numeric identifier so G18 precedes G131", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)

      g131 = goal_with_identifier(column, "G131")
      g18 = goal_with_identifier(column, "G18")
      g9 = goal_with_identifier(column, "G9")

      for goal <- [g131, g18, g9], do: assert({:ok, _} = Targets.assign_goal(scope, goal, target))

      identifiers =
        scope |> Targets.list_member_goal_details(target) |> Enum.map(& &1.goal.identifier)

      assert identifiers == ["G9", "G18", "G131"]
    end
  end

  describe "list_assignable_goal_details/2" do
    test "returns details only for unassigned goals on accessible boards", %{
      scope: scope,
      user: user,
      column: column,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)

      unassigned = goal_fixture(column)
      already_here = goal_fixture(column)
      foreign = goal_fixture(other_column)
      assert {:ok, _} = Targets.assign_goal(scope, already_here, target)

      ids = scope |> Targets.list_assignable_goal_details(target) |> Enum.map(& &1.goal.id)

      assert unassigned.id in ids
      refute already_here.id in ids
      refute foreign.id in ids
    end

    test "excludes archived goals when exclude_archived: true", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      live = goal_fixture(column)
      archived = goal_fixture(column)
      {:ok, _} = Kanban.Tasks.archive_task(archived)

      ids =
        scope
        |> Targets.list_assignable_goal_details(target, exclude_archived: true)
        |> Enum.map(& &1.goal.id)

      assert live.id in ids
      refute archived.id in ids
    end

    test "includes archived goals when the option is not set (default unchanged)", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      archived = goal_fixture(column)
      {:ok, _} = Kanban.Tasks.archive_task(archived)

      ids = scope |> Targets.list_assignable_goal_details(target) |> Enum.map(& &1.goal.id)

      assert archived.id in ids
    end

    test "board scoping still applies with exclude_archived: true", %{
      scope: scope,
      user: user,
      column: column,
      other_column: other_column
    } do
      target = delivery_target_fixture(user)
      mine = goal_fixture(column)
      foreign = goal_fixture(other_column)

      ids =
        scope
        |> Targets.list_assignable_goal_details(target, exclude_archived: true)
        |> Enum.map(& &1.goal.id)

      assert mine.id in ids
      refute foreign.id in ids
    end

    test "returns the goal_progress_detail shape with flow and fraction",
         %{scope: scope, user: user, board: board, column: column} do
      goal = goal_fixture(column)
      ready = column_fixture(board, %{name: "Ready"})
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      task_fixture(ready, %{parent_id: goal.id})

      target = delivery_target_fixture(user)

      assert [entry] =
               scope
               |> Targets.list_assignable_goal_details(target)
               |> Enum.filter(&(&1.goal.id == goal.id))

      assert Map.keys(entry) |> Enum.sort() ==
               [:completed, :flow, :goal, :percentage, :total]

      # The completed child sits in the default (unnamed) column, so it buckets
      # to :backlog by column name even though its status counts as completed.
      assert entry.flow == %{backlog: 1, ready: 1, doing: 0, review: 0, done: 0, total: 2}
      assert entry.completed == 1
      assert entry.total == 2
      assert entry.percentage == 50
    end

    test "each returned goal has :column and :assigned_to preloaded",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)

      assert [entry] =
               scope
               |> Targets.list_assignable_goal_details(target)
               |> Enum.filter(&(&1.goal.id == goal.id))

      assert Ecto.assoc_loaded?(entry.goal.column)
      assert Ecto.assoc_loaded?(entry.goal.assigned_to)
    end

    test "excludes work tasks and goals already assigned to another target", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)
      other_target = delivery_target_fixture(user)

      work = task_fixture(column, %{type: :work})
      assigned_elsewhere = goal_fixture(column)
      assert {:ok, _} = Targets.assign_goal(scope, assigned_elsewhere, other_target)

      ids = scope |> Targets.list_assignable_goal_details(target) |> Enum.map(& &1.goal.id)
      refute work.id in ids
      refute assigned_elsewhere.id in ids
    end

    test "returns [] when there are no unassigned goals",
         %{scope: scope, user: user} do
      target = delivery_target_fixture(user)
      assert Targets.list_assignable_goal_details(scope, target) == []
    end

    test "orders detail entries by numeric identifier so G18 precedes G131", %{
      scope: scope,
      user: user,
      column: column
    } do
      target = delivery_target_fixture(user)

      goal_with_identifier(column, "G131")
      goal_with_identifier(column, "G18")
      goal_with_identifier(column, "G9")

      identifiers =
        scope |> Targets.list_assignable_goal_details(target) |> Enum.map(& &1.goal.identifier)

      assert identifiers == ["G9", "G18", "G131"]
    end
  end

  describe "get_target_progress/3 — archived work crediting (D124)" do
    @today ~D[2026-07-07]

    test "a fully-archived, finished goal reads complete (100%) and the target status is :complete",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      target = delivery_target_fixture(user)
      {:ok, goal} = Targets.assign_goal(scope, goal, target)
      # Archiving cascades to the (completed) children and never flips the goal's
      # own status — the exact shape that previously collapsed the goal to 0/0.
      {:ok, _} = Kanban.Tasks.archive_task(goal)

      %{summary: summary, goals: [entry]} =
        Targets.get_target_progress(scope, target, @today)

      assert entry.completed == 2
      assert entry.total == 2
      assert entry.percentage == 100
      # Archived-completed children bucket as :done so the segmented bar agrees
      # with the 2-of-2 count instead of rendering empty.
      assert entry.flow == %{backlog: 0, ready: 0, doing: 0, review: 0, done: 2, total: 2}
      assert summary.status == :complete
    end

    test "an archived-completed child is credited toward completed/total", %{
      scope: scope,
      user: user,
      column: column
    } do
      goal = goal_fixture(column)
      archived_done = complete_task(task_fixture(column, %{parent_id: goal.id}))
      {:ok, _} = Kanban.Tasks.archive_task(archived_done)
      _live_incomplete = task_fixture(column, %{parent_id: goal.id})

      target = delivery_target_fixture(user)
      {:ok, _} = Targets.assign_goal(scope, goal, target)

      %{goals: [entry]} = Targets.get_target_progress(scope, target, @today)

      # 1 archived-completed + 1 live-incomplete => 1 of 2 (not 0 of 1).
      assert entry.completed == 1
      assert entry.total == 2
      assert entry.percentage == 50
    end

    test "an archived-but-unfinished child is dropped, not counted (as complete or as pending)",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal.id}))

      cancelled = task_fixture(column, %{parent_id: goal.id})

      {:ok, _} =
        Kanban.Tasks.archive_task(cancelled, %{
          archive_reason: :cancelled,
          archive_note: "descoped"
        })

      target = delivery_target_fixture(user)
      {:ok, _} = Targets.assign_goal(scope, goal, target)

      %{goals: [entry]} = Targets.get_target_progress(scope, target, @today)

      # The archived-cancelled child leaves the fraction entirely: 1 of 1, not
      # 1 of 2 (which would understate) and not 2 of 2 (which would over-credit).
      assert entry.completed == 1
      assert entry.total == 1
      assert entry.percentage == 100
    end

    test "a goal archived as :wontdo does NOT read complete", %{
      scope: scope,
      user: user,
      column: column
    } do
      goal = goal_fixture(column)

      {:ok, goal} =
        Kanban.Tasks.archive_task(goal, %{archive_reason: :wontdo, archive_note: "descoped"})

      target = delivery_target_fixture(user)
      {:ok, _} = Targets.assign_goal(scope, goal, target)

      %{summary: summary} = Targets.get_target_progress(scope, target, @today)

      refute summary.status == :complete
    end

    test "a target mixing an archived-complete goal with a genuinely incomplete goal is NOT :complete",
         %{scope: scope, user: user, column: column} do
      done_goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: done_goal.id}))

      open_goal = goal_fixture(column)
      _incomplete = task_fixture(column, %{parent_id: open_goal.id})

      target = delivery_target_fixture(user)
      {:ok, done_goal} = Targets.assign_goal(scope, done_goal, target)
      {:ok, _} = Targets.assign_goal(scope, open_goal, target)
      {:ok, _} = Kanban.Tasks.archive_task(done_goal)

      %{summary: summary, goals: goals} = Targets.get_target_progress(scope, target, @today)

      refute summary.status == :complete

      done_entry = Enum.find(goals, &(&1.goal.id == done_goal.id))
      open_entry = Enum.find(goals, &(&1.goal.id == open_goal.id))
      assert done_entry.percentage == 100
      assert open_entry.percentage == 0
    end
  end

  defp complete_task(task) do
    {:ok, done} =
      task
      |> Task.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
      |> Repo.update()

    done
  end
end
