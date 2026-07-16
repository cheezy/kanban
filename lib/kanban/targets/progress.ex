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
    * `Kanban.Targets.Status.derive/3`'s **work-share** counts a childless goal
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
  `summarize_target_with_goals/3` into a summarize call plus a second goal fetch
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

  `today` is passed in by `Kanban.Targets` at its impure boundary so
  `Kanban.Targets.Status.derive/3` stays pure and never reads the clock. The one
  exception is `derive_target_status/2` (the archive gate), which anchors UTC
  internally — see its own comment for why that is sound.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Queries
  alias Kanban.Targets.Status
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @typedoc """
  One boards-page summary row for a delivery target: the target itself, its
  read-time derived `Kanban.Targets.Status`, and the aggregate child-task
  progress used by the targets strip.
  """
  @type target_summary :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          percentage: 0..100
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
  The aggregate `target_summary/0` for one target — the boards-strip row.
  """
  @spec summarize_target(Scope.t() | nil, DeliveryTarget.t(), Date.t()) :: target_summary()
  def summarize_target(scope, %DeliveryTarget{} = target, today) do
    {summary, _goals} = summarize_target_with_goals(scope, target, today)
    summary
  end

  @doc """
  Summarizes a target AND returns its member goals, fetching the member-goal
  list exactly once.

  Both the aggregate summary (the boards strip) and callers that need the raw
  `[Task.t()]` goal list (`Kanban.Targets.DeliveryRollup`, via
  `Kanban.Targets.list_targets_with_status_and_goals/2`) share this single
  fetch, so the member-goal query runs once per target instead of twice.
  `Queries.list_member_goals/2` preloads `:column`, so each goal's own board_id
  scopes its batched child-task query in `member_goal_children/1`.

  Do not "simplify" this into a `summarize_target/3` call plus a second goal
  fetch: the values would stay correct and the query count would double.
  """
  @spec summarize_target_with_goals(Scope.t() | nil, DeliveryTarget.t(), Date.t()) ::
          {target_summary(), [Task.t()]}
  def summarize_target_with_goals(scope, %DeliveryTarget{} = target, today) do
    {progress, goals} = member_goal_progress(scope, target)

    {summarize_progress(target, progress, today), goals}
  end

  @doc """
  A target's status derived from its member goals right now, for the archive
  gate.

  Unlike `Kanban.Targets.list_targets_with_status/2`, this takes no injectable
  `today` — it anchors UTC internally. That is sufficient *here* because the gate
  reads only the `:complete` verdict, and `Status.derive/3` decides `:complete`
  (all member goals complete) before any `today`-dependent branch. So no
  timezone can change whether a target is archivable. A caller that needs a
  timezone-sensitive status (`:missed` / `:at_risk`) must go through
  `Kanban.Targets.list_targets_with_status/2` and pass its own `today`.
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
  `aggregate_children/1`, `percentage/2`, and `Status.derive/3` helpers.
  """
  @spec build_target_progress(Scope.t() | nil, DeliveryTarget.t(), Date.t()) :: target_progress()
  def build_target_progress(scope, %DeliveryTarget{} = target, today) do
    details =
      scope
      |> Queries.list_member_goals(target)
      |> goal_detail_entries()

    progress = Enum.map(details, & &1.progress)

    %{
      summary: summarize_progress(target, progress, today),
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

  # The `Status.derive/3` progress shape for each of `target`'s member goals,
  # plus the goals themselves — one member-goal query and one batched child
  # query. Shared by `summarize_target_with_goals/3` (the boards strip) and
  # `derive_target_status/2` (the archive gate) so the assembly lives in exactly
  # one place and the two can never drift apart on what "complete" means.
  #
  # Returns the goals alongside the progress so `summarize_target_with_goals/3`
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
  # `Status`-progress shapes. Shared by `summarize_target/3` (the boards strip)
  # and `build_target_progress/3` (the drill-down) so the status/fraction math
  # lives in exactly one place.
  defp summarize_progress(%DeliveryTarget{} = target, progress, today) do
    {completed, total} = aggregate_children(progress)

    %{
      target: target,
      status: Status.derive(target, progress, today),
      completed: completed,
      total: total,
      percentage: percentage(completed, total)
    }
  end

  # The `Kanban.Targets.Status.derive/3` progress shape for one goal, computed
  # once here so the aggregate (`summarize_target/3`, `build_target_progress/3`)
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
  # only `Status.derive/3` needs.
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
