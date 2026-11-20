defmodule Kanban.Targets.AppTargets do
  @moduledoc """
  The app's Targets list and Target screen (`GET /api/me/targets` and `GET
  /api/me/targets/:id`, W2763, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.16, §6.17, §7.10).

  It composes `Kanban.Targets.DeliveryRollup`, `Kanban.Targets` and
  `Kanban.Plans` and runs no query of its own, so the status, the estimate and
  the counts are the web's, never the app's. It is called directly by
  `KanbanWeb.API.Me.TargetController`, so `Kanban.Targets`, already over the
  module-size guideline, does not grow.

  ## The time zone

  Both reads take `:timezone`, the device's zone, else `"Etc/UTC"`, and read
  `now` in it once, so the rollup and the target's progress derive against the
  same local instant (D123, D212), as `/agents` and `/targets/:id` derive
  against the browser's. `:now` exists for tests.

  ## The list

  `DeliveryRollup.build/2`'s targets, in its order (soonest target date first):
  every active target with at least one member goal on a board the person can
  see, as `/agents` and the boards strip list them. Archived targets are left
  out. Each row carries the rollup's status and estimate, the `completed` and
  `total` task counts of its summary, the member-goal count and `owner`
  (`Kanban.Targets.owner?/2`).

  Plans on cross-board lists (design §7.10): member goals on boards the plan
  does not unlock (`Kanban.Plans.unlocked_board_ids/1`) are left out of
  `goal_count`, and a target with no member goal on an unlocked board is left
  out of the list. A target's status and counts stay the web's.

  ## The detail

  Owner only: `Kanban.Targets.get_owned_target/2` answers `{:error,
  :not_found}` for anyone else. The counts and member goals are
  `Kanban.Targets.get_target_progress/3`'s, as `/targets/:id` reads them; the
  status, the estimate and the stalled goals are the target's rollup entry
  (`Kanban.Targets.DeliveryRollup.build_target/3`, the entry `build/2` gives
  it, built for this target alone), as the risk explanation on `/agents`
  reads them. An owned target the rollup
  has no entry for (archived, or with no visible member goal) takes its status
  and estimate from its progress summary and has no stalled goals. Goal rows
  and stalled goals on boards outside the plan are left out.

  `risk` is present only when the status is `:at_risk` and there is a reason
  to give, as `KanbanWeb.TargetRiskExplainer` decides it: an estimate that
  slipped past the target date (`Kanban.Targets.Status.slipped?/2`), or
  stalled goals. Each stalled goal names its stalled agents with their
  reasons, `:stuck` and/or `:dormant`, in that order.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Agents.Agent
  alias Kanban.Plans
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Status
  alias Kanban.Tasks
  alias Kanban.Tasks.AppGoals
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @type row :: %{
          target: DeliveryTarget.t(),
          status: Status.status(),
          estimated_completion_date: Date.t() | nil,
          goal_count: non_neg_integer(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          owner: boolean()
        }

  @type stalled_agent :: %{name: String.t(), reasons: [:stuck | :dormant]}

  @type stalled_goal :: %{goal: Task.t(), agents: [stalled_agent()]}

  @type risk :: %{
          slipped: %{estimate: Date.t(), target_date: Date.t()} | nil,
          stalled: [stalled_goal()]
        }

  @type detail :: %{target: row(), goals: [AppGoals.entry()], risk: risk() | nil}

  @doc """
  The person's targets, as `t:row/0`. Options: `:timezone` (default
  `"Etc/UTC"`) and `:now`. A scope with no user lists nothing.
  """
  @spec list(Scope.t() | nil, keyword()) :: [row()]
  def list(scope, opts \\ [])

  def list(%Scope{user: %User{} = user} = scope, opts) do
    {zone, now} = clock(opts)
    entries = DeliveryRollup.build(scope, timezone: zone, now: now).targets
    unlocked = entries |> Enum.flat_map(& &1.goals) |> unlocked()

    entries
    |> Enum.map(&list_row(&1, unlocked, user))
    |> Enum.reject(&(&1.goal_count == 0))
  end

  def list(_scope, _opts), do: []

  @doc """
  The Target screen for the target `id` the person owns, as `t:detail/0`.
  Options as `list/2`. `{:error, :not_found}` when the person does not own
  it, it does not exist, or the scope has no user.
  """
  @spec detail(Scope.t() | nil, integer(), keyword()) :: {:ok, detail()} | {:error, :not_found}
  def detail(scope, id, opts \\ []) do
    with {:ok, target} <- Targets.get_owned_target(scope, id) do
      {zone, now} = clock(opts)
      progress = Targets.get_target_progress(scope, target, now)
      {:ok, build_detail(target, progress, rollup_entry(scope, zone, now, target))}
    end
  end

  defp build_detail(target, progress, entry) do
    goals = Enum.map(progress.goals, & &1.goal)
    unlocked = unlocked(goals)
    visible = Enum.filter(goals, &on_unlocked?(&1, unlocked))
    {status, estimate} = status_and_estimate(entry, progress.summary)

    %{
      target: %{
        target: target,
        status: status,
        estimated_completion_date: estimate,
        goal_count: length(visible),
        completed: progress.summary.completed,
        total: progress.summary.total,
        owner: true
      },
      goals: Tasks.goal_rows_for_app(visible),
      risk: risk(status, estimate, target.target_date, stalled(entry, unlocked))
    }
  end

  @doc """
  The risk reason for a target, or `nil` when there is none to give: only an
  `:at_risk` status with a slipped estimate or stalled goals has one.
  """
  @spec risk(Status.status(), Date.t() | nil, Date.t(), [stalled_goal()]) :: risk() | nil
  def risk(:at_risk, estimate, target_date, stalled) do
    case {slipped(estimate, target_date), stalled} do
      {nil, []} -> nil
      {slipped, stalled} -> %{slipped: slipped, stalled: stalled}
    end
  end

  def risk(_status, _estimate, _target_date, _stalled), do: nil

  @doc "An agent's stall reasons, `:stuck` before `:dormant`."
  @spec reasons(Agent.t()) :: [:stuck | :dormant]
  def reasons(%Agent{stuck: stuck, dormant: dormant}) do
    [{stuck, :stuck}, {dormant, :dormant}]
    |> Enum.filter(fn {flag, _reason} -> flag end)
    |> Enum.map(fn {_flag, reason} -> reason end)
  end

  defp clock(opts) do
    zone = Keyword.get(opts, :timezone) || "Etc/UTC"
    {zone, Keyword.get(opts, :now) || Timezone.local_now(zone)}
  end

  defp list_row(entry, unlocked, user) do
    %{
      target: entry.target,
      status: entry.status,
      estimated_completion_date: entry.estimated_completion_date,
      goal_count: Enum.count(entry.goals, &on_unlocked?(&1, unlocked)),
      completed: entry.completed,
      total: entry.total,
      owner: Targets.owner?(entry.target, user)
    }
  end

  defp rollup_entry(scope, zone, now, %DeliveryTarget{} = target),
    do: DeliveryRollup.build_target(scope, target, timezone: zone, now: now)

  defp status_and_estimate(nil, summary), do: {summary.status, summary.estimated_completion_date}
  defp status_and_estimate(entry, _summary), do: {entry.status, entry.estimated_completion_date}

  defp stalled(nil, _unlocked), do: []

  defp stalled(entry, unlocked) do
    entry.stalled_details
    |> Enum.filter(&on_unlocked?(&1.goal, unlocked))
    |> Enum.map(fn %{goal: goal, agents: agents} ->
      %{goal: goal, agents: Enum.map(agents, &%{name: &1.name, reasons: reasons(&1)})}
    end)
  end

  defp slipped(estimate, target_date) do
    if Status.slipped?(estimate, target_date),
      do: %{estimate: estimate, target_date: target_date}
  end

  defp unlocked(goals) do
    goals |> Enum.map(&board_id/1) |> Enum.uniq() |> Plans.unlocked_board_ids()
  end

  defp on_unlocked?(goal, unlocked), do: MapSet.member?(unlocked, board_id(goal))

  defp board_id(%Task{column: %{board_id: board_id}}), do: board_id
end
