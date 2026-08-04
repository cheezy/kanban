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
  # `Status.derive/4` reads as `:complete` (all_complete?/1 trusts the goal's
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
      # Status.derive/4 reads an empty goal list as :on_track, never a vacuous
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
      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-07 00:00:00Z])

      assert summary.target.id == target.id
      assert summary.completed == 1
      assert summary.total == 2
      assert summary.percentage == 50
      assert summary.status == :on_track
    end

    test "no longer includes a target once it is archived",
         %{scope: scope, user: user, column: column} do
      target = complete_target(scope, column, user)

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-07 00:00:00Z])
      assert summary.target.id == target.id
      assert summary.status == :complete

      assert {:ok, _} = Targets.archive_target(scope, target.id)

      # The boards feed is built on list_targets/1, so the is_nil filter there
      # is what removes an archived target from the boards page.
      assert Targets.list_targets_with_status(scope, ~U[2026-07-07 00:00:00Z]) == []
    end

    test "reports 0/0 (0%) progress when a member goal has no children",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-07 00:00:00Z])
      assert summary.completed == 0
      assert summary.total == 0
      assert summary.percentage == 0
    end

    test "excludes targets whose goals are all on inaccessible boards",
         %{scope: scope, user: user, column: column, other_scope: other_scope} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert Targets.list_targets_with_status(other_scope, ~U[2026-07-07 00:00:00Z]) == []
    end
  end

  # The anchor is an instant (D212); @estimate_today stays a Date because the
  # expectations below are built with Date.add/2. Midnight is deliberate: every
  # fixture here uses whole-day leads, and a whole-day product from a midnight
  # anchor lands exactly on midnight N days on — so these expected values are
  # unchanged by the move from date arithmetic to instant projection.
  @estimate_now ~U[2026-07-07 00:00:00Z]
  @estimate_today ~D[2026-07-07]

  # A completed historical (non-child) task with an EXACT lead time of
  # `days`, both timestamps pinned so assertions never depend on the wall
  # clock. inserted_at is not castable to the past through the changeset, so
  # this bypasses the cast allow-list the same way goal_with_identifier/3
  # does.
  defp completed_with_lead(column, days), do: completed_with_lead_seconds(column, days * 86_400)

  # The seconds-granularity form, and the one that does the work — the
  # whole-day helper above delegates here. Sub-day leads exist for the D212
  # cases: a whole-day lead cannot distinguish an instant projection from the
  # old whole-day arithmetic, because it lands on the same calendar day either
  # way. A sub-day lead is the only kind that can.
  defp completed_with_lead_seconds(column, seconds) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(
      status: :completed,
      completed_at: ~U[2026-07-01 12:00:00Z],
      inserted_at: NaiveDateTime.add(~N[2026-07-01 12:00:00], -seconds)
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

  describe "every read path estimates from one batched sample (W1951)" do
    test "ignores history on boards outside the viewer's scope, on every read path",
         %{scope: scope, user: user, column: column, other_column: other_column} do
      # The batched union may only ever contain boards the viewer can reach.
      # other_column belongs to a board the viewer is not a member of, so its
      # history must not pace this target on ANY path.
      completed_with_lead(other_column, 3)
      target = target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == nil

      assert [with_goals] = Targets.list_targets_with_status_and_goals(scope, @estimate_now)
      assert with_goals.estimated_completion_date == nil

      assert %{summary: drill_down} =
               Targets.get_target_progress(scope, target, @estimate_now)

      assert drill_down.estimated_completion_date == nil
    end

    test "a target is not paced by another target's boards",
         %{scope: scope, user: user, column: column} do
      # Both targets are summarized in ONE call, so they share one query — but
      # each must still be paced only by its own boards. Flattening the by-board
      # sample across the batch would give the history-less target B's pace.
      second_board = board_fixture(user)
      second_column = column_fixture(second_board)
      completed_with_lead(second_column, 3)

      _history_less = target_with_remaining(scope, column, user, 1)
      _with_history = target_with_remaining(scope, second_column, user, 1)

      assert [a, b] = Targets.list_targets_with_status(scope, @estimate_now)

      assert Enum.sort([a.estimated_completion_date, b.estimated_completion_date]) ==
               Enum.sort([nil, Date.add(@estimate_today, 3)])
    end

    test "pools history across every board backing a target's member goals",
         %{scope: scope, user: user, column: column} do
      # One target, two goals on two different boards the viewer owns: leads of
      # 1 and 3 days pool to a p50 of 2 days, 1 remaining -> today + 2.
      second_board = board_fixture(user)
      second_column = column_fixture(second_board)
      completed_with_lead(column, 1)
      completed_with_lead(second_column, 3)

      target = delivery_target_fixture(user)
      first_goal = goal_fixture(column)
      second_goal = goal_fixture(second_column)
      task_fixture(second_column, %{parent_id: second_goal.id})
      assert {:ok, _} = Targets.assign_goal(scope, first_goal, target)
      assert {:ok, _} = Targets.assign_goal(scope, second_goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 2)
    end

    test "a viewer with access to no boards summarizes nothing",
         %{scope: scope, user: user, column: column, other_scope: other_scope} do
      completed_with_lead(column, 2)
      target_with_remaining(scope, column, user, 1)

      assert Targets.list_targets_with_status(other_scope, @estimate_now) == []
      assert Targets.list_targets_with_status_and_goals(other_scope, @estimate_now) == []
    end
  end

  describe "list_targets_with_status/2 — estimated_completion_date" do
    test "projects today + remaining * p50 lead time from board history",
         %{scope: scope, user: user, column: column} do
      # Historical leads of 1/2/4 days -> p50 = 2.0 days; 2 remaining
      # children -> 4.0 days -> today + 4.
      for days <- [1, 2, 4], do: completed_with_lead(column, days)
      target_with_remaining(scope, column, user, 2)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 4)
    end

    test "D212: remaining work that fits inside today estimates TODAY end to end",
         %{scope: scope, user: user, column: column} do
      # The reported symptom, reproduced through the real read path rather than
      # the pure math: a 6-hour median with one task left, anchored at 08:00,
      # finishes at 14:00 the same day. Pre-fix this reported tomorrow.
      #
      # This case is what a fix confined to Kanban.Targets.Estimation would not
      # satisfy — if Progress still handed a bare date down, the unit suite
      # would be green and this would fail.
      for _ <- 1..3, do: completed_with_lead_seconds(column, 6 * 3_600)
      target_with_remaining(scope, column, user, 1)

      morning = ~U[2026-07-07 08:00:00Z]

      assert [summary] = Targets.list_targets_with_status(scope, morning)
      assert summary.estimated_completion_date == @estimate_today
    end

    test "D212: the same remaining work rolls to tomorrow from a late anchor",
         %{scope: scope, user: user, column: column} do
      # Non-vacuity control for the case above: identical fixture, later anchor.
      for _ <- 1..3, do: completed_with_lead_seconds(column, 6 * 3_600)
      target_with_remaining(scope, column, user, 1)

      evening = ~U[2026-07-07 20:00:00Z]

      assert [summary] = Targets.list_targets_with_status(scope, evening)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 1)
    end

    test "is nil when there are no historical completed tasks",
         %{scope: scope, user: user, column: column} do
      target_with_remaining(scope, column, user, 2)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == nil
    end

    test "ignores completed goal-type tasks in the historical sample",
         %{scope: scope, user: user, column: column} do
      column |> goal_fixture() |> complete_task()
      target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == nil
    end

    test "ignores history on boards not backing the target's member goals",
         %{scope: scope, user: user, column: column, other_column: other_column} do
      completed_with_lead(other_column, 3)
      target_with_remaining(scope, column, user, 1)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
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

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.estimated_completion_date == Date.add(@estimate_today, 2)
    end

    test "is nil for a :complete target even with history present",
         %{scope: scope, user: user, column: column} do
      completed_with_lead(column, 2)
      complete_target(scope, column, user)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.status == :complete
      assert summary.estimated_completion_date == nil
    end

    test "is nil for an all-complete target that still has remaining children",
         %{scope: scope, user: user, column: column} do
      # The only shape that isolates the all-goals-complete gate from the
      # remaining == 0 gate: the goal itself is complete, so the target is
      # :complete, but its children are not — remaining is 2, and without the
      # first gate the sample query would project a date.
      completed_with_lead(column, 2)
      goal = column |> goal_fixture() |> complete_task()
      for _ <- 1..2, do: task_fixture(column, %{parent_id: goal.id})
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.status == :complete
      assert summary.total - summary.completed == 2
      assert summary.estimated_completion_date == nil
    end

    test "still estimates when only some member goals are complete",
         %{scope: scope, user: user, column: column} do
      # Two member goals — one complete, one carrying 2 incomplete children.
      # Suppression requires EVERY goal complete: an any-complete reading of
      # the gate would wrongly suppress a still-valid estimate here.
      for days <- [1, 2, 4], do: completed_with_lead(column, days)
      target = delivery_target_fixture(user)
      done_goal = column |> goal_fixture() |> complete_task()
      open_goal = goal_fixture(column)
      for _ <- 1..2, do: task_fixture(column, %{parent_id: open_goal.id})
      assert {:ok, _} = Targets.assign_goal(scope, done_goal, target)
      assert {:ok, _} = Targets.assign_goal(scope, open_goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      refute summary.status == :complete
      assert summary.estimated_completion_date == Date.add(@estimate_today, 4)
    end

    test "is nil when nothing remains (childless 0/0 goal) even with history",
         %{scope: scope, user: user, column: column} do
      completed_with_lead(column, 2)
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert [summary] = Targets.list_targets_with_status(scope, @estimate_now)
      assert summary.status == :on_track
      assert summary.total == 0
      assert summary.estimated_completion_date == nil
    end

    test "the rollup and drill-down paths estimate from the same batched sample",
         %{scope: scope, user: user, column: column} do
      # W1951 flipped this: every badge-rendering read path now estimates, and
      # all three read the same value the boards strip does above.
      for days <- [1, 2, 4], do: completed_with_lead(column, days)
      target = target_with_remaining(scope, column, user, 2)

      assert [with_goals] =
               Targets.list_targets_with_status_and_goals(scope, @estimate_now)

      assert with_goals.estimated_completion_date == Date.add(@estimate_today, 4)

      assert %{summary: summary} =
               Targets.get_target_progress(scope, target, @estimate_now)

      assert summary.estimated_completion_date == Date.add(@estimate_today, 4)
    end
  end

  # The reported D182 production shape: a target whose estimate lands Jul 27,
  # evaluated on Jul 26. Work share is high enough (0.9 completed against a
  # fully elapsed 30-day window — a 0.10 gap, under the 0.15 threshold) that
  # the lag check does NOT fire, so any :at_risk verdict comes from the slip.
  #
  # `target_date` is a parameter because the same fixture proves the
  # non-slipping cases: with a later due date the estimate is unchanged but the
  # status must stay :on_track.
  defp slipping_target(scope, column, user, target_date, lead_seconds \\ 86_400) do
    target = delivery_target_fixture(user, %{target_date: target_date})

    # Backdate creation to open a 30-day window ending Jul 26. inserted_at is
    # not castable through the changeset, so this bypasses the cast allow-list
    # the same way goal_with_identifier/3 does.
    target =
      target
      |> Ecto.Changeset.change(inserted_at: ~U[2026-06-26 00:00:00.000000Z])
      |> Repo.update!()

    goal = goal_fixture(column)

    # 9 children completed with an EXACT `lead_seconds` lead — they are also the
    # historical sample, so p50 == lead_seconds — and 1 still open ->
    # remaining == 1. At the default 1-day lead that puts the estimate at
    # Jul 26 + 1 = Jul 27; a sub-day lead keeps it inside Jul 26 (D212).
    for _ <- 1..9 do
      column
      |> task_fixture(%{parent_id: goal.id})
      |> Ecto.Changeset.change(
        status: :completed,
        completed_at: ~U[2026-07-01 12:00:00Z],
        inserted_at: NaiveDateTime.add(~N[2026-07-01 12:00:00], -lead_seconds)
      )
      |> Repo.update!()
    end

    task_fixture(column, %{parent_id: goal.id})
    assert {:ok, _} = Targets.assign_goal(scope, goal, target)

    target
  end

  describe "list_targets_with_status/2 — estimate slip raises :at_risk (D182)" do
    test "a boards-strip target whose estimate slips past its target date reads :at_risk",
         %{scope: scope, user: user, column: column} do
      slipping_target(scope, column, user, ~D[2026-07-26])

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-26 00:00:00Z])
      # Assert the estimate first: it proves the verdict came from the slip and
      # not from a lag miscalculation.
      assert summary.estimated_completion_date == ~D[2026-07-27]
      assert summary.completed == 9 and summary.total == 10
      assert summary.status == :at_risk
    end

    test "D212: a target finishing inside today is no longer badged :at_risk on its target date",
         %{scope: scope, user: user, column: column} do
      # The user-visible payoff of D212, and the second half of acceptance
      # criterion 6. Identical shape to the slip case above — 9 of 10 done,
      # one task left, evaluated ON the target date — but with a 6-hour median
      # instead of a 1-day one.
      #
      # Pre-fix, the whole-day ceil put the estimate at Jul 27, one day past the
      # Jul 26 target, so a target that would plainly finish by lunchtime was
      # badged at-risk. The estimate must now land on Jul 26 and the badge must
      # not fire.
      slipping_target(scope, column, user, ~D[2026-07-26], 6 * 3_600)

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-26 08:00:00Z])

      assert summary.estimated_completion_date == ~D[2026-07-26]
      assert summary.completed == 9 and summary.total == 10
      refute summary.status == :at_risk
    end

    test "D212: the same target IS still badged :at_risk from a late-evening anchor",
         %{scope: scope, user: user, column: column} do
      # Non-vacuity control: the same fixture whose estimate fits inside the day
      # at 08:00 genuinely does not fit at 20:00, so the slip — and the badge —
      # must return. Without this, a fix that simply stopped slipping would pass
      # the case above.
      slipping_target(scope, column, user, ~D[2026-07-26], 6 * 3_600)

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-26 20:00:00Z])

      assert summary.estimated_completion_date == ~D[2026-07-27]
      assert summary.status == :at_risk
    end

    test "an estimate ON the target date leaves the status unchanged",
         %{scope: scope, user: user, column: column} do
      slipping_target(scope, column, user, ~D[2026-07-27])

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-26 00:00:00Z])
      assert summary.estimated_completion_date == ~D[2026-07-27]
      assert summary.status == :on_track
    end

    test "an estimate before the target date leaves the status unchanged",
         %{scope: scope, user: user, column: column} do
      slipping_target(scope, column, user, ~D[2026-07-28])

      assert [summary] = Targets.list_targets_with_status(scope, ~U[2026-07-26 00:00:00Z])
      assert summary.estimated_completion_date == ~D[2026-07-27]
      assert summary.status == :on_track
    end

    test "every read path derives :at_risk from the same slip",
         %{scope: scope, user: user, column: column} do
      # W1951 flipped this: the rollup and drill-down now receive the same
      # estimate the boards strip does, so the badge is no longer
      # path-dependent — the asymmetry D182 documented is gone.
      target = slipping_target(scope, column, user, ~D[2026-07-26])

      assert [with_goals] =
               Targets.list_targets_with_status_and_goals(scope, ~U[2026-07-26 00:00:00Z])

      assert with_goals.estimated_completion_date == ~D[2026-07-27]
      assert with_goals.status == :at_risk

      assert %{summary: summary} =
               Targets.get_target_progress(scope, target, ~U[2026-07-26 00:00:00Z])

      assert summary.estimated_completion_date == ~D[2026-07-27]
      assert summary.status == :at_risk
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

      [expected] = Targets.list_targets_with_status(scope, ~U[2026-07-07 00:00:00Z])

      assert %{summary: summary} =
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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

      assert %{goals: [entry]} =
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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

      assert %{goals: [entry]} =
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

      assert entry.flow == %{backlog: 0, ready: 1, doing: 0, review: 0, done: 0, total: 1}
      assert entry.completed == 1
      assert entry.total == 1
    end

    test "a member goal with no children yields an all-zero flow map",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      assert %{goals: [entry]} =
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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
               Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])

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
               Targets.get_target_progress(other_scope, target, ~U[2026-07-07 00:00:00Z])

      assert summary.total == 0
    end

    test "accepts a target id, resolving it through the board-scoped get_target/2",
         %{scope: scope, user: user, column: column} do
      goal = goal_fixture(column)
      complete_task(task_fixture(column, %{parent_id: goal.id}))
      target = delivery_target_fixture(user)
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      by_struct = Targets.get_target_progress(scope, target, ~U[2026-07-07 00:00:00Z])
      by_id = Targets.get_target_progress(scope, target.id, ~U[2026-07-07 00:00:00Z])

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
    @now ~U[2026-07-07 00:00:00Z]

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
        Targets.get_target_progress(scope, target, @now)

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

      %{goals: [entry]} = Targets.get_target_progress(scope, target, @now)

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

      %{goals: [entry]} = Targets.get_target_progress(scope, target, @now)

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

      %{summary: summary} = Targets.get_target_progress(scope, target, @now)

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

      %{summary: summary, goals: goals} = Targets.get_target_progress(scope, target, @now)

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
