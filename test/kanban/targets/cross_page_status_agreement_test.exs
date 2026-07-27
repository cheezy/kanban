defmodule Kanban.Targets.CrossPageStatusAgreementTest do
  @moduledoc """
  Regression guard for D123: the boards page, the target-detail page, and the
  agents delivery-health band must derive the SAME status for the same target
  and the same viewer.

  All three surfaces route through the single shared derivation
  `Kanban.Targets.Status.derive/4`; the divergent input D123 was filed for was
  `today`. The boards/target-detail paths anchored on the server's UTC day
  (`Date.utc_today/0`) while the agents band anchored on the viewer's
  browser-local day (`Kanban.Timezone.local_today/1`). For a viewer west of UTC
  near UTC midnight those two calendar days differ by one, which flips
  `:at_risk` <-> `:on_track` across the 0.15 lag threshold.

  These tests pin the fix at the context layer using the explicit `today` seam
  the three read paths already expose, so the discrepancy cannot silently
  return.

  ## The second divergent input: the estimate (D182, closed by W1951)

  `today` is no longer the only input the three paths must share. D182 made the
  estimated completion date a derivation input, and for one task only the
  boards strip computed one — so a target whose estimate slipped past its date
  read `:at_risk` there while the other two surfaces read `:on_track`. W1951
  closed that by supplying the estimate on every badge read path from a single
  batched lead-time query.

  The D123 fixtures cannot see the estimate seam: they contain no completed
  tasks, so the sample is empty and every path sees a `nil` estimate — their
  agreement is real for `today` and vacuous for the estimate. The
  "cross-page estimate agreement (W1951)" describe below is what covers it
  non-vacuously, with a fixture whose badge is decided by the estimate alone
  (the lag check is deliberately kept under its threshold) plus a control case
  proving the `:at_risk` came from the slip and not from lag drift.
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

  # A target whose ESTIMATE — not its lag — decides its badge. Created Jun 26,
  # evaluated Jul 26: a 30-day window, fully elapsed, with 9 of 10 children
  # complete => work_share 0.9 and a 0.10 gap, UNDER the 0.15 lag threshold, so
  # the lag check does not fire. today == the Jul 26 target date, so it is not
  # :missed either. The 9 completed children ARE the lead-time sample, each an
  # exact 1-day lead => p50 = 1 day; remaining = 1 => the estimate is Jul 27,
  # strictly after Jul 26, and therefore the only possible cause of :at_risk.
  @slip_created ~N[2026-06-26 00:00:00]
  @slip_today ~D[2026-07-26]
  @slip_target_date ~D[2026-07-26]
  @slip_estimate ~D[2026-07-27]

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

    %{scope: scope, target: target, user: user, doing: doing}
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

  describe "cross-page estimate agreement (W1951)" do
    test "all three read paths read :at_risk from the same slipping estimate", ctx do
      target = slipping_target(ctx.user, ctx.doing, @slip_target_date)

      assert status_via_boards(ctx.scope, target, @slip_today) == :at_risk
      assert status_via_target_detail(ctx.scope, target, @slip_today) == :at_risk
      assert status_via_agents(ctx.scope, target, @slip_today) == :at_risk
    end

    test "all three read paths report the same estimate", ctx do
      target = slipping_target(ctx.user, ctx.doing, @slip_target_date)

      assert estimate_via_boards(ctx.scope, target, @slip_today) == @slip_estimate
      assert estimate_via_target_detail(ctx.scope, target, @slip_today) == @slip_estimate
      assert estimate_via_agents_source(ctx.scope, target, @slip_today) == @slip_estimate
    end

    test "with a later target date the same estimate is no slip, on every path", ctx do
      # The non-vacuity control: the estimate is unchanged at Jul 27, but Jul 27
      # is no longer past the target date, so every path reads :on_track. If the
      # :at_risk above came from lag drift rather than the slip, this fails too.
      target = slipping_target(ctx.user, ctx.doing, ~D[2026-07-28])

      assert estimate_via_boards(ctx.scope, target, @slip_today) == @slip_estimate
      assert status_via_boards(ctx.scope, target, @slip_today) == :on_track
      assert status_via_target_detail(ctx.scope, target, @slip_today) == :on_track
      assert status_via_agents(ctx.scope, target, @slip_today) == :on_track
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

  # The same three paths, read for their estimate rather than their status. The
  # agents band renders a badge and no date, so its rollup entry carries no
  # estimate key — assert on its SOURCE, the summary DeliveryRollup consumes.
  defp estimate_via_boards(scope, target, today) do
    [summary] =
      scope
      |> Targets.list_targets_with_status(today)
      |> Enum.filter(&(&1.target.id == target.id))

    summary.estimated_completion_date
  end

  defp estimate_via_target_detail(scope, target, today) do
    Targets.get_target_progress(scope, target, today).summary.estimated_completion_date
  end

  defp estimate_via_agents_source(scope, target, today) do
    scope
    |> Targets.list_targets_with_status_and_goals(today)
    |> Enum.find(&(&1.target.id == target.id))
    |> Map.fetch!(:estimated_completion_date)
  end

  defp slipping_target(user, doing, target_date) do
    target = delivery_target_fixture(user, %{name: "Slipping", target_date: target_date})
    backdate_target(target, @slip_created)
    target = Repo.get!(DeliveryTarget, target.id)

    goal = goal_on_target(doing, target)

    for _ <- 1..9 do
      doing
      |> task_fixture(%{parent_id: goal.id})
      |> Ecto.Changeset.change(
        status: :completed,
        completed_at: ~U[2026-07-01 12:00:00Z],
        inserted_at: ~N[2026-06-30 12:00:00]
      )
      |> Repo.update!()
    end

    task_fixture(doing, %{parent_id: goal.id})

    target
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
