defmodule Kanban.Targets.CrossPageStatusAgreementTest do
  @moduledoc """
  Regression guard for D123: the boards page, the target-detail page, and the
  agents delivery-health band must derive the SAME status for the same target
  and the same viewer.

  All three surfaces route through the single shared derivation
  `Kanban.Targets.Status.derive/3`; the only divergent input was `today`. The
  boards/target-detail paths anchored on the server's UTC day
  (`Date.utc_today/0`) while the agents band anchored on the viewer's
  browser-local day (`Kanban.Timezone.local_today/1`). For a viewer west of UTC
  near UTC midnight those two calendar days differ by one, which flips
  `:at_risk` <-> `:on_track` across the 0.15 lag threshold.

  These tests pin the fix at the context layer using the explicit `today` seam
  the three read paths already expose, so the discrepancy cannot silently
  return.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  # A target created 2026-06-01 due 2026-07-21 has a 50-day window, so
  # elapsed_share advances 0.02 per day. With no completed work (work_share
  # 0.0), the 0.15 lag threshold is crossed between day 7 (0.14 => :on_track)
  # and day 8 (0.16 => :at_risk) — a clean one-calendar-day flip, both sides
  # clear of the exact-threshold boundary.
  @created_on ~N[2026-06-01 00:00:00]
  @target_date ~D[2026-07-21]
  @on_track_day ~D[2026-06-08]
  @at_risk_day ~D[2026-06-09]

  setup do
    user = user_fixture()
    board = board_fixture(user)
    doing = column_fixture(board, %{name: "Doing"})
    scope = Scope.for_user(user)

    target =
      delivery_target_fixture(user, %{name: "Ships soon", target_date: @target_date})

    backdate_target(target, @created_on)
    # Reload so the in-memory struct carries the backdated inserted_at (the
    # target-detail path derives created_on from the struct we pass it).
    target = Repo.get!(DeliveryTarget, target.id)

    # One member goal with a single incomplete child => work_share 0.0, so the
    # status is driven purely by elapsed calendar time (the `today` input).
    goal = goal_on_target(doing, target)
    _incomplete_child = task_fixture(doing, %{parent_id: goal.id})

    %{scope: scope, target: target}
  end

  describe "cross-page status agreement (D123)" do
    test "all three read paths agree for a given anchored today", %{scope: scope, target: target} do
      for today <- [@on_track_day, @at_risk_day] do
        boards = status_via_boards(scope, target, today)
        detail = status_via_target_detail(scope, target, today)
        agents = status_via_agents(scope, target, today)

        assert boards == detail
        assert detail == agents
      end
    end

    test "status flips across a one-day today shift, on every path", %{
      scope: scope,
      target: target
    } do
      for status_fun <- [
            &status_via_boards/3,
            &status_via_target_detail/3,
            &status_via_agents/3
          ] do
        assert status_fun.(scope, target, @on_track_day) == :on_track
        assert status_fun.(scope, target, @at_risk_day) == :at_risk
      end
    end

    test "a viewer-local vs server-UTC one-day gap diverges, so all three must share the anchor",
         %{scope: scope, target: target} do
      # Pre-fix: boards/target-detail used the server UTC day while the agents
      # band used the viewer's browser-local day. For a viewer west of UTC near
      # UTC midnight the local day is one earlier — exactly this gap.
      server_utc_day = @at_risk_day
      viewer_local_day = @on_track_day

      # The reported symptom: the boards page (UTC anchor) reads :at_risk while
      # the agents band (viewer-local anchor) reads :on_track for the SAME
      # target and viewer.
      refute status_via_boards(scope, target, server_utc_day) ==
               status_via_agents(scope, target, viewer_local_day)

      # The fix anchors all three on the SAME (viewer-local) day, so they agree.
      assert status_via_boards(scope, target, viewer_local_day) ==
               status_via_agents(scope, target, viewer_local_day)

      assert status_via_target_detail(scope, target, viewer_local_day) ==
               status_via_agents(scope, target, viewer_local_day)
    end
  end

  # The three read paths, each fed the same explicit `today`. These mirror the
  # exact context calls the boards page, target-detail page, and agents band
  # make (see lib/kanban_web/live/{board_live/index,target_live/show,agents_live}.ex).

  defp status_via_boards(scope, target, today) do
    [summary] =
      scope
      |> Targets.list_targets_with_status(today)
      |> Enum.filter(&(&1.target.id == target.id))

    summary.status
  end

  defp status_via_target_detail(scope, target, today) do
    Targets.get_target_progress(scope, target, today).summary.status
  end

  defp status_via_agents(scope, target, today) do
    rollup = DeliveryRollup.build(scope, today: today)
    Enum.find(rollup.targets, &(&1.target.id == target.id)).status
  end

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  defp backdate_target(%DeliveryTarget{id: id}, %NaiveDateTime{} = at) do
    from(t in DeliveryTarget, where: t.id == ^id)
    |> Repo.update_all(set: [inserted_at: at])
  end
end
