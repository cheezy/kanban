defmodule Kanban.Targets.Progress do
  @moduledoc """
  Progress and summary math for delivery targets and their member goals.

  `Kanban.Targets` is the public API; this module is one of its two internal
  helpers. `Kanban.Targets.Queries` owns the *fetching*, this module owns the
  *math* over what is fetched, and `Targets` composes the two. Nothing here
  builds an Ecto query — a function that does belongs in `Queries`. This module
  does perform child-task reads (through `Kanban.Tasks`), because a goal's
  children are an input to its progress and fetching them per goal is part of
  the aggregation this module defines.

  ## Two intentionally separate measures

  Two different notions of "progress" coexist here, and conflating them is the
  bug this module's structure exists to prevent:

    * The **display fraction** (`aggregate_children/1`) counts child tasks. A
      childless goal contributes `0/0` — it does not move the fraction.
    * `Kanban.Targets.Status.derive/4`'s **work-share** counts a childless goal
      as one unit.

  Both are derived from the same `progress_shape/2` output, computed once per
  goal, so the aggregate and the per-goal breakdown can never drift apart.

  ## The once-per-target member-goal query

  `member_goal_progress/2` runs the member-goal query **exactly once** and
  returns `{progress, goals}` — the `Status` progress shapes *and* the raw goal
  list. Both consumers share that single fetch: the boards-strip summary, and
  `Kanban.Targets.DeliveryRollup` (via `list_targets_with_status_and_goals/2`),
  which needs the raw `[Task.t()]`.

  This is a load-bearing invariant, not an optimization detail. Splitting
  `summarize_targets/3` into per-target summarize calls plus a second goal fetch
  returns identical *values* while doubling the query count — a regression only
  `test/kanban/targets/delivery_rollup_query_count_test.exs` and
  `test/kanban_web/live/agents_live_query_count_test.exs` can see.

  ## Archived work (D124)

  Child fetches include archived children. Archived-*completed* work is credited
  toward the fraction; archived-*incomplete* work (wontdo/duplicate/deferred/
  cancelled) is treated as removed and drops out of both counts rather than
  dragging the denominator down. The same rule decides whether a *goal* counts
  as complete.

  ## Time injection

  `now` — a timezone-aware `DateTime` — is passed in by `Kanban.Targets` at its
  impure boundary so `Kanban.Targets.Status.derive/4` and
  `Kanban.Targets.Estimation` stay pure and never read the clock. The one
  exception is `derive_target_status/2` (the archive gate), which anchors UTC
  internally — see its own comment for why that is sound.

  The anchor is a single instant, not an instant *and* a date. `Status` needs a
  `Date` and `Estimation` needs the time of day, so `summarize_batch/2` derives
  `today` from `now` in exactly one place. Two independently-supplied time
  values is the shape of D123 (paths disagreeing about `today`) and of D212
  (the time of day silently discarded) — deriving one from the other is what
  makes those disagreements unrepresentable rather than merely unlikely.

  ## Estimated completion (W1729, batched in W1951)

  Every `target_summary/0` carries an `:estimated_completion_date` key, and
  **every badge-rendering read path computes it** — the boards strip, the
  /agents rollup, and the target-detail drill-down all route through
  `summarize_batch/2`. A badge derived from an estimate on one surface and
  from no estimate on another is the cross-page divergence D123 was filed for,
  so the estimate is not an opt-in.

  The estimate itself is `Kanban.Targets.Estimation` math over the sample
  `Kanban.Targets.Queries.list_completed_lead_times_by_board/1` fetches. It is gated
  here BEFORE the sample query fires: a target whose every member goal is
  complete, or a remaining count of `0`, yields `nil` with no query. The
  remaining count is `total - completed` from the same D124-credited
  `aggregate_children/1` counts the displayed fraction uses, so the two can
  never disagree.

  Both gate conditions read the member-goal progress snapshot directly, never
  the derived `Kanban.Targets.Status` (W1950). The estimate therefore depends
  only on that snapshot, the member goals, and `now` — it is computed
  independently of the status rather than after it, so the status is free to
  become a consumer of the estimate without creating a cycle.

  ## Estimate-driven :at_risk (D182)

  The estimate is computed BEFORE the status and passed into
  `Kanban.Targets.Status.derive/4`, so an estimate later than the target date
  reads `:at_risk` — the earliest concrete signal a target will be late, and
  one that fires even when a high work share suppresses the lag check.

  ## Batched lead-time sample (W1951)

  `summarize_batch/2` gathers, gates, queries once, then re-pools:

    1. **Gather** — `member_goal_progress/2` per target (unchanged, still one
       member-goal query per target), because a target's boards are only
       knowable once its member goals are fetched.
    2. **Gate** — `remaining_to_pace/1` per target, BEFORE any sample query, so
       a batch in which nothing is estimable (and an empty batch) still issues
       zero lead-time queries.
    3. **One query** — the union of the estimable targets' board ids goes to
       `Queries.list_completed_lead_times_by_board/1` exactly once per batch,
       so the marginal per-target cost of the estimate is **zero queries**
       (the budget the query-count tests above pin).
    4. **Re-pool** — each target's estimate is paced only by the boards backing
       its OWN member goals, read back out of the by-board map.

  Step 4 is load-bearing: pooling the map's values across the batch would let
  one target's history pace another, which
  `test/kanban/targets_test.exs`'s "ignores history on boards not backing the
  target's member goals" exists to catch. The union in step 3 is built only
  from ids read off scope-filtered member goals, so batching never widens the
  viewer's board scope.

  ## Paths that do not estimate

  Two paths derive no estimate, deliberately, because neither renders a badge:

    * `derive_target_status/2` — the archive gate. It reads only the
      `:complete` verdict, which `Kanban.Targets.Status.derive/4` resolves
      before any `:at_risk` branch, so an estimate could not change its answer.
    * `goal_detail_views/1` — per-*goal* detail shapes. They carry no
      `:status` key and derive no target status at all, so there is no badge
      to be inconsistent about.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Estimation
  alias Kanban.Targets.Queries
  alias Kanban.Targets.Status
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @typedoc """
  One boards-page summary row for a delivery target: the target itself, its
  read-time derived `Kanban.Targets.Status`, the aggregate child-task
  progress used by the targets strip, and the projected
  `:estimated_completion_date` (`nil` when every member goal is complete,
  nothing remains, or there is no historical lead-time sample — see the
  moduledoc's "Estimated completion" section).
  """
  @type target_summary :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100,
          estimated_completion_date: Date.t() | nil
        }

  @typedoc """
  A `target_summary/0` that also carries the target's member goal tasks under
  `:goals` (`:column` preloaded, same structs `Kanban.Targets.list_member_goals/2`
  returns). Returned by `Kanban.Targets.list_targets_with_status_and_goals/2` so
  a caller needing both the status summary and the raw goal list fetches the
  member goals once.
  """
  @type target_summary_with_goals :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100,
          estimated_completion_date: Date.t() | nil,
          goals: [Task.t()]
        }

  @typedoc """
  A single goal's child-task flow, bucketed by the child's *column name*
  (not `task.status`), mirroring the boards Goals view. Every key is present
  even when zero, and `:total` is the sum of the five column buckets.
  """
  @type goal_flow :: %{
          done: non_neg_integer(),
          review: non_neg_integer(),
          doing: non_neg_integer(),
          ready: non_neg_integer(),
          backlog: non_neg_integer(),
          total: non_neg_integer()
        }

  @typedoc """
  One member goal's progress detail: the goal task, its column-bucketed
  `:flow` map, and its completed/total/percentage child fraction.
  """
  @type goal_progress_detail :: %{
          goal: Task.t(),
          flow: goal_flow(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100
        }

  @typedoc """
  The full progress payload for a single target: the same aggregate
  `target_summary/0` the boards strip uses, plus a per-goal breakdown.
  """
  @type target_progress :: %{
          summary: target_summary(),
          goals: [goal_progress_detail()]
        }

  @doc """
  Summarizes a whole list of targets — the shape every badge-rendering read
  path uses — fetching each target's member goals exactly once AND the
  historical lead-time sample exactly ONCE for the entire list.

  Returns `{summary, goals}` per target, in the order given. Callers that need
  only the summary drop the goals; `Kanban.Targets.DeliveryRollup` (via
  `Kanban.Targets.list_targets_with_status_and_goals/2`) keeps them, so the
  member-goal query runs once per target instead of twice.
  `Queries.list_member_goals/2` preloads `:column`, so each goal's own board_id
  scopes its batched child-task query in `member_goal_children/1`.

  Do not "simplify" this into a per-target summarize call: the values would
  stay correct while the member-goal query count doubled and the lead-time
  query went from one per request to one per target — a regression only
  `test/kanban/targets/delivery_rollup_query_count_test.exs` and
  `test/kanban_web/live/agents_live_query_count_test.exs` can see.
  """
  @spec summarize_targets(Scope.t() | nil, [DeliveryTarget.t()], DateTime.t()) ::
          [{target_summary(), [Task.t()]}]
  def summarize_targets(scope, targets, now) do
    targets
    |> Enum.map(fn %DeliveryTarget{} = target ->
      {progress, goals} = member_goal_progress(scope, target)
      {target, progress, goals}
    end)
    |> summarize_batch(now)
  end

  @doc """
  A target's status derived from its member goals right now, for the archive
  gate.

  Unlike `Kanban.Targets.list_targets_with_status/2`, this takes no injectable
  `today` — it anchors UTC internally. That is sufficient *here* because the gate
  reads only the `:complete` verdict, and `Status.derive/4` decides `:complete`
  (all member goals complete) before any `today`-dependent branch. So no
  timezone can change whether a target is archivable. A caller that needs a
  timezone-sensitive status (`:missed` / `:at_risk`) must go through
  `Kanban.Targets.list_targets_with_status/2` and pass its own `now`.

  It is also the one read path that deliberately derives WITHOUT an estimate
  (see the moduledoc's "Paths that do not estimate"), which cannot affect the
  `:complete` verdict the gate reads: the estimate slip only ever raises
  `:at_risk`, a branch below `:complete` in the precedence order.
  """
  @spec derive_target_status(Scope.t() | nil, DeliveryTarget.t()) :: Status.status()
  def derive_target_status(scope, %DeliveryTarget{} = target) do
    {progress, _goals} = member_goal_progress(scope, target)

    Status.derive(target, progress, Date.utc_today())
  end

  @doc """
  The full progress payload for one already-resolved target — the aggregate
  summary the boards strip renders, plus a per-goal breakdown.

  The target-level aggregate and the per-goal breakdown both derive from the
  single `details` list — one child fetch per goal — reusing the shared
  `aggregate_children/1`, `percentage/2`, and `Status.derive/4` helpers.

  The summary is built through the same `summarize_batch/2` the list paths use,
  as a batch of one, so the drill-down badge is derived from an estimate
  computed exactly the way the boards strip and the /agents band compute
  theirs. That structural sharing — not a duplicated helper the two paths must
  keep in step — is what makes the badge path-independent (W1951).
  """
  @spec build_target_progress(Scope.t() | nil, DeliveryTarget.t(), DateTime.t()) ::
          target_progress()
  def build_target_progress(scope, %DeliveryTarget{} = target, now) do
    details =
      scope
      |> Queries.list_member_goals(target)
      |> goal_detail_entries()

    progress = Enum.map(details, & &1.progress)
    goals = Enum.map(details, & &1.goal)

    [{summary, _goals}] = summarize_batch([{target, progress, goals}], now)

    %{
      summary: summary,
      goals: Enum.map(details, &goal_detail_view/1)
    }
  end

  @doc """
  Maps a list of `:column`-preloaded goals to the public `goal_progress_detail/0`
  shape. The DRY entry point for `Kanban.Targets.list_member_goal_details/2` and
  `Kanban.Targets.list_assignable_goal_details/3`.

  Preserves the order of the goals it is given — it never re-sorts. `Queries`
  has already ordered them by numeric identifier.
  """
  @spec goal_detail_views([Task.t()]) :: [goal_progress_detail()]
  def goal_detail_views(goals) do
    goals
    |> goal_detail_entries()
    |> Enum.map(&goal_detail_view/1)
  end

  # The `Status.derive/4` progress shape for each of `target`'s member goals,
  # plus the goals themselves — one member-goal query and one batched child
  # query. Shared by `summarize_targets/3` (every badge read path) and
  # `derive_target_status/2` (the archive gate) so the assembly lives in exactly
  # one place and the two can never drift apart on what "complete" means.
  #
  # Returns the goals alongside the progress so `summarize_targets/3`
  # can hand them to `DeliveryRollup` without a second fetch, preserving the
  # once-per-target member-goal query this module documents.
  defp member_goal_progress(scope, %DeliveryTarget{} = target) do
    goals = Queries.list_member_goals(scope, target)
    children_by_goal = member_goal_children(goals)

    progress =
      Enum.map(goals, fn goal ->
        progress_shape(goal, Map.get(children_by_goal, goal.id, []))
      end)

    {progress, goals}
  end

  # Fetches every member goal's child tasks (archived included, per D124) in one
  # query per distinct board instead of one per goal, bounding the per-goal N+1
  # the rollup used to fire on every /agents refresh (D125).
  # Queries.list_member_goals/2 preloads :column, so each goal's board scopes its
  # own children.
  defp member_goal_children(goals) do
    goals
    |> Enum.map(&{&1.id, &1.column.board_id})
    |> Tasks.get_children_including_archived_by_parent()
  end

  # The aggregate `target_summary/0` for a target given its member goals'
  # `Status`-progress shapes. Shared by `summarize_batch/2` (the list paths)
  # and `build_target_progress/3` (the drill-down) so the status/fraction math
  # lives in exactly one place.
  #
  # `estimate` is the already-computed estimated completion date, or `nil` for
  # the paths that do not estimate (the drill-down, the rollup, and the archive
  # gate). The single value both feeds `Status.derive/4` — an estimate past the
  # target date reads :at_risk (D182) — and becomes the summary's
  # `:estimated_completion_date`, so the badge and the displayed date can never
  # disagree about which estimate they saw.
  defp summarize_progress(%DeliveryTarget{} = target, progress, today, estimate) do
    {completed, total} = aggregate_children(progress)

    %{
      target: target,
      status: Status.derive(target, progress, today, estimate),
      completed: completed,
      total: total,
      percentage: percentage(completed, total),
      estimated_completion_date: estimate
    }
  end

  # Summarizes already-fetched {target, progress, goals} triples, fetching the
  # historical lead-time sample ONCE for the whole batch. Every badge-rendering
  # read path funnels through here — the boards strip, the /agents rollup, and
  # the target-detail drill-down (a batch of one) — so the estimate a badge is
  # derived from can never be path-dependent (D123 / W1951).
  defp summarize_batch(triples, now) do
    paced = Enum.map(triples, &pace/1)
    sample = batched_lead_times(paced)

    # The ONE place `now` becomes a `Date`. Status needs the calendar day and
    # Estimation needs the time of day; deriving the former from the latter here
    # is what makes them structurally unable to disagree. A future caller that
    # reintroduces a separately-supplied `today` reintroduces D123 with it.
    today = DateTime.to_date(now)

    Enum.map(paced, &summarize_paced(&1, sample, now, today))
  end

  # Tags a fetched triple with what it has left to pace, so the gate is decided
  # once — before the batched fetch reads it, and again when each estimate is
  # computed.
  defp pace({target, progress, goals}) do
    {target, progress, goals, remaining_to_pace(progress)}
  end

  # One summary from a paced triple plus the batch's shared by-board sample.
  # Takes both halves of the single anchor: `now` paces the estimate, `today`
  # (derived from it in summarize_batch/2) is what Status derives against.
  defp summarize_paced({target, progress, goals, remaining}, sample, now, today) do
    estimate = estimate(remaining, goals, sample, now)

    {summarize_progress(target, progress, today, estimate), goals}
  end

  # One query for the union of the boards backing the member goals of the
  # targets that still have work to pace. The gate runs FIRST, so a batch with
  # nothing estimable — and an empty batch — issues no query at all, preserving
  # the "gate before the sample query" property at the set level.
  #
  # The union can only ever contain board ids read off scope-filtered member
  # goals, so it never widens the caller's board scope.
  defp batched_lead_times(paced) do
    paced
    |> Enum.flat_map(fn
      {_target, _progress, _goals, nil} -> []
      {_target, _progress, goals, _remaining} -> board_ids(goals)
    end)
    |> Enum.uniq()
    |> Queries.list_completed_lead_times_by_board()
  end

  # One target's estimate, paced ONLY by the boards backing its own member goals
  # — never by the rest of the batch. Re-pooling per target from the shared
  # by-board sample is what makes the batched fetch observationally identical to
  # the per-target fetch it replaced; flattening the map across targets instead
  # (Map.values/1) would let one target's history pace another.
  defp estimate(nil, _goals, _sample, _now), do: nil

  defp estimate(remaining, goals, sample, now) do
    goals
    |> board_ids()
    |> Enum.flat_map(&Map.get(sample, &1, []))
    |> Estimation.estimated_completion_date(remaining, now)
  end

  # The remaining child-task count to pace, or nil when there is nothing to
  # estimate. A target whose every member goal is complete has nothing left to
  # pace, and a remaining count of 0 (childless 0/0 target, or all credited work
  # done while a goal is still open) would make an unmoved projection a meaningless
  # promise.
  #
  # Read from the member-goal progress snapshot alone, never from the derived
  # status (W1950), and from the same `aggregate_children/1` counts the
  # displayed fraction uses, so the estimate and the fraction can never disagree.
  defp remaining_to_pace(progress) do
    {completed, total} = aggregate_children(progress)
    remaining = total - completed

    if all_goals_complete?(progress) or remaining == 0, do: nil, else: remaining
  end

  # The distinct boards backing a target's member goals. `:column` is preloaded
  # by `Queries.list_member_goals/2`, so this costs no query.
  defp board_ids(goals), do: goals |> Enum.map(& &1.column.board_id) |> Enum.uniq()

  # Every member goal complete, per the same stored goal_complete? flag
  # `Kanban.Targets.Status.derive/4` reads for its :complete verdict — so this
  # gate suppresses exactly the targets the old `%{status: :complete}` match
  # did. The one input the two read differently is an empty progress list, which
  # `derive/4` calls :on_track while `Enum.all?/2` is vacuously true; that is
  # output-neutral, because a childless target's remaining count is 0 and the
  # next gate returns nil down either path.
  defp all_goals_complete?(progress), do: Enum.all?(progress, & &1.goal_complete?)

  # The `Kanban.Targets.Status.derive/4` progress shape for one goal, computed
  # once here so the aggregate (`summarize_targets/3`, `build_target_progress/3`)
  # and the per-goal breakdown never duplicate the completed/total math.
  #
  # `children` includes archived children (fetched via
  # `get_task_children_including_archived/2`): archived-completed work is
  # credited toward the fraction, archived-incomplete work is treated as removed
  # (dropped from both counts). See D124.
  defp progress_shape(%Task{} = goal, children) do
    credited = Enum.filter(children, &credited_child?/1)

    %{
      completed_children: Enum.count(credited, &(&1.status == :completed)),
      total_children: length(credited),
      goal_complete?: goal_complete?(goal)
    }
  end

  # A child counts toward the goal's completed/total fraction when it is live
  # (not archived) or archived-but-completed. Archived-incomplete children
  # (wontdo/duplicate/deferred/cancelled) are removed work and drop out of the
  # fraction entirely rather than dragging the denominator down. See D124.
  defp credited_child?(%Task{archived_at: nil}), do: true
  defp credited_child?(%Task{status: status}), do: status == :completed

  # A goal is complete when its own status is :completed, or it has been
  # archived as finished work — archive_reason :completed, or legacy nil. A goal
  # archived as :wontdo/:duplicate/:deferred/:cancelled is abandoned, not
  # complete, so it must not credit the target toward :complete. See D124.
  defp goal_complete?(%Task{status: :completed}), do: true
  defp goal_complete?(%Task{archived_at: nil}), do: false
  defp goal_complete?(%Task{archive_reason: reason}), do: reason in [:completed, nil]

  # Maps a list of `:column`-preloaded goals to their internal detail entries
  # (one child fetch each). Shared by `build_target_progress/3` (which also
  # needs each entry's `:progress`) and `goal_detail_views/1`.
  defp goal_detail_entries(goals), do: Enum.map(goals, &goal_detail_entry/1)

  # The public per-goal detail shape — drops the internal `:progress` key that
  # only `Status.derive/4` needs.
  defp goal_detail_view(detail) do
    Map.take(detail, [:goal, :flow, :completed, :total, :percentage])
  end

  # One member goal's detail: fetches its child tasks once (with `:column`
  # preloaded for flow bucketing), then derives the Status progress shape, the
  # column-bucketed flow map, and the completed/total/percentage fraction from
  # that single fetch.
  defp goal_detail_entry(%Task{} = goal) do
    children =
      goal.id
      |> Tasks.get_task_children_including_archived(goal.column.board_id)
      |> Repo.preload(:column)

    progress = progress_shape(goal, children)

    %{
      goal: goal,
      flow: flow_map(Enum.filter(children, &credited_child?/1)),
      completed: progress.completed_children,
      total: progress.total_children,
      percentage: percentage(progress.completed_children, progress.total_children),
      progress: progress
    }
  end

  # Display fraction across every member goal's child tasks (childless goals
  # add 0/0). Distinct from Status.derive's work-share, which counts a childless
  # goal as one unit — the two measures are intentionally separate.
  defp aggregate_children(progress) do
    Enum.reduce(progress, {0, 0}, fn gp, {done, total} ->
      {done + gp.completed_children, total + gp.total_children}
    end)
  end

  defp percentage(_completed, 0), do: 0
  defp percentage(completed, total), do: round(completed / total * 100)

  @empty_flow %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

  # Buckets a goal's child tasks into %{done, review, doing, ready, backlog,
  # total} by each child's column NAME (never task.status), matching the boards
  # Goals view. Children must have :column preloaded.
  defp flow_map(children) do
    Enum.reduce(children, @empty_flow, fn child, acc ->
      bucket = flow_bucket_for(child)

      acc
      |> Map.update!(bucket, &(&1 + 1))
      |> Map.update!(:total, &(&1 + 1))
    end)
  end

  # Archived-completed children are credited into the progress fraction but are
  # hidden from the board, so their stale column must not drive a bucket — count
  # them as :done. Live children bucket by their column name as before. See D124.
  defp flow_bucket_for(%Task{archived_at: at, column: column}) do
    if is_nil(at), do: flow_bucket(column), else: :done
  end

  # Maps a column name to its flow bucket. Duplicates the tiny name→status case
  # from KanbanWeb.BoardLive.Show.column_status/1 deliberately: a context must
  # not depend on the web layer. Any unknown/nil column falls back to :backlog.
  defp flow_bucket(%{name: name}) when is_binary(name) do
    case String.downcase(name) do
      "backlog" -> :backlog
      "ready" -> :ready
      "doing" -> :doing
      "review" -> :review
      "done" -> :done
      _ -> :backlog
    end
  end

  defp flow_bucket(_), do: :backlog
end
