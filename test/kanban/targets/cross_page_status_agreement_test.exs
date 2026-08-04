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

  These tests pin the fix at the context layer using the explicit anchor seam
  the three read paths already expose, so the discrepancy cannot silently
  return.

  ## The anchor is now an instant (D212)

  That shared anchor is a `DateTime`, not a `Date`. The completion estimate has
  to know how much of the local day is left — a target one task from done at
  08:00 must read *today*, not tomorrow — and the calendar day the status
  derives against is taken from that same instant downstream, so the two can
  never disagree. The whole-day fixtures below are unaffected by the change: a
  whole-day product from a midnight anchor lands exactly on midnight N days on.
  The "sub-day estimate" test in the estimate-agreement describe is the one
  that can actually see the difference, and it exists because a partial fix —
  repairing the math but leaving one read path collapsing its anchor to a date
  — would otherwise ship silently, which is the exact D123 failure shape.

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
  @on_track_day ~U[2026-06-08 00:00:00Z]
  @at_risk_day ~U[2026-06-09 00:00:00Z]

  # A target whose ESTIMATE — not its lag — decides its badge. Created Jun 26,
  # evaluated Jul 26: a 30-day window, fully elapsed, with 9 of 10 children
  # complete => work_share 0.9 and a 0.10 gap, UNDER the 0.15 lag threshold, so
  # the lag check does not fire. today == the Jul 26 target date, so it is not
  # :missed either. The 9 completed children ARE the lead-time sample, each an
  # exact 1-day lead => p50 = 1 day; remaining = 1 => the estimate is Jul 27,
  # strictly after Jul 26, and therefore the only possible cause of :at_risk.
  @slip_created ~N[2026-06-26 00:00:00]
  @slip_now ~U[2026-07-26 00:00:00Z]
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
      for now <- [@on_track_day, @at_risk_day] do
        boards = status_via_boards(scope, target, now)
        detail = status_via_target_detail(scope, target, now)
        agents = status_via_agents(scope, target, now)

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

      assert status_via_boards(ctx.scope, target, @slip_now) == :at_risk
      assert status_via_target_detail(ctx.scope, target, @slip_now) == :at_risk
      assert status_via_agents(ctx.scope, target, @slip_now) == :at_risk
    end

    test "all three read paths report the same estimate", ctx do
      target = slipping_target(ctx.user, ctx.doing, @slip_target_date)

      assert estimate_via_boards(ctx.scope, target, @slip_now) == @slip_estimate
      assert estimate_via_target_detail(ctx.scope, target, @slip_now) == @slip_estimate
      assert estimate_via_agents_source(ctx.scope, target, @slip_now) == @slip_estimate
    end

    test "with a later target date the same estimate is no slip, on every path", ctx do
      # The non-vacuity control: the estimate is unchanged at Jul 27, but Jul 27
      # is no longer past the target date, so every path reads :on_track. If the
      # :at_risk above came from lag drift rather than the slip, this fails too.
      target = slipping_target(ctx.user, ctx.doing, ~D[2026-07-28])

      assert estimate_via_boards(ctx.scope, target, @slip_now) == @slip_estimate
      assert status_via_boards(ctx.scope, target, @slip_now) == :on_track
      assert status_via_target_detail(ctx.scope, target, @slip_now) == :on_track
      assert status_via_agents(ctx.scope, target, @slip_now) == :on_track
    end

    test "all three paths agree on a SUB-DAY estimate that resolves to today (D212)", ctx do
      # The whole-day fixtures above cannot see the D212 seam: a whole-day
      # product lands on the same calendar day whatever the anchor's time of
      # day, so a path that collapsed its anchor to a Date would still agree.
      # This fixture's 6-hour median with one task left resolves to TODAY from
      # an 08:00 anchor and TOMORROW from an 20:00 one — so any path that
      # discards the time of day disagrees with the two that do not.
      target = sub_day_target(ctx.user, ctx.doing)
      morning = ~U[2026-07-26 08:00:00Z]

      assert estimate_via_boards(ctx.scope, target, morning) == ~D[2026-07-26]
      assert estimate_via_target_detail(ctx.scope, target, morning) == ~D[2026-07-26]
      assert estimate_via_agents_source(ctx.scope, target, morning) == ~D[2026-07-26]
    end

    test "the same sub-day estimate rolls to tomorrow from a late anchor, on every path", ctx do
      # Non-vacuity control for the case above: identical fixture, later anchor.
      # Without this, a path hard-coding "today" would pass the morning case.
      target = sub_day_target(ctx.user, ctx.doing)
      evening = ~U[2026-07-26 20:00:00Z]

      assert estimate_via_boards(ctx.scope, target, evening) == ~D[2026-07-27]
      assert estimate_via_target_detail(ctx.scope, target, evening) == ~D[2026-07-27]
      assert estimate_via_agents_source(ctx.scope, target, evening) == ~D[2026-07-27]
    end
  end

  # The three read paths, each fed the same explicit `today`. These mirror the
  # exact context calls the boards page, target-detail page, and agents band
  # make (see lib/kanban_web/live/{board_live/index,target_live/show,agents_live}.ex).

  defp status_via_boards(scope, target, now) do
    [summary] =
      scope
      |> Targets.list_targets_with_status(now)
      |> Enum.filter(&(&1.target.id == target.id))

    summary.status
  end

  defp status_via_target_detail(scope, target, now) do
    Targets.get_target_progress(scope, target, now).summary.status
  end

  defp status_via_agents(scope, target, now) do
    rollup = DeliveryRollup.build(scope, now: now)
    Enum.find(rollup.targets, &(&1.target.id == target.id)).status
  end

  # The same three paths, read for their estimate rather than their status. The
  # agents band renders a badge and no date, so its rollup entry carries no
  # estimate key — assert on its SOURCE, the summary DeliveryRollup consumes.
  defp estimate_via_boards(scope, target, now) do
    [summary] =
      scope
      |> Targets.list_targets_with_status(now)
      |> Enum.filter(&(&1.target.id == target.id))

    summary.estimated_completion_date
  end

  defp estimate_via_target_detail(scope, target, now) do
    Targets.get_target_progress(scope, target, now).summary.estimated_completion_date
  end

  defp estimate_via_agents_source(scope, target, now) do
    scope
    |> Targets.list_targets_with_status_and_goals(now)
    |> Enum.find(&(&1.target.id == target.id))
    |> Map.fetch!(:estimated_completion_date)
  end

  # A target whose remaining work is a FRACTION of a day: 9 children completed
  # at an exact 6-hour lead (p50 = 6h) and one still open (remaining = 1). From
  # an 08:00 anchor the projection lands at 14:00 the same day; from 20:00 it
  # lands at 02:00 the next. The generous target date keeps the badge out of it
  # — this fixture exists to exercise the estimate, not the status.
  defp sub_day_target(user, doing) do
    target_with_lead(user, doing, "Sub-day", ~D[2026-08-30], 6 * 3_600)
  end

  defp slipping_target(user, doing, target_date) do
    target_with_lead(user, doing, "Slipping", target_date, 86_400)
  end

  # 9 children completed at an EXACT `lead_seconds` lead — they are also the
  # by-board lead-time sample, so p50 == lead_seconds — plus one still open, so
  # remaining == 1. The lead is what the two fixtures above actually differ on.
  defp target_with_lead(user, doing, name, target_date, lead_seconds) do
    target = delivery_target_fixture(user, %{name: name, target_date: target_date})
    backdate_target(target, @slip_created)
    target = Repo.get!(DeliveryTarget, target.id)

    goal = goal_on_target(doing, target)

    for _ <- 1..9 do
      doing
      |> task_fixture(%{parent_id: goal.id})
      |> Ecto.Changeset.change(
        status: :completed,
        completed_at: ~U[2026-07-01 12:00:00Z],
        inserted_at: NaiveDateTime.add(~N[2026-07-01 12:00:00], -lead_seconds)
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
