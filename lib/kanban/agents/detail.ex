defmodule Kanban.Agents.Detail do
  @moduledoc """
  Builds the per-agent drill-down shown on the `/agents` detail panel — the
  agent's current task, claim history, review failures, recent activity, daily
  activity series, and outcome breakdown.

  Extracted from `Kanban.Agents` so the drill-down derivation lives behind a
  single-responsibility boundary (mirroring `Kanban.Agents.Metrics`). The
  shared task set and per-task primitives come from `Kanban.Agents`, the event
  shape from `Kanban.Agents.Events`, and the activity series from
  `Kanban.Agents.Metrics`. `Kanban.Agents.agent_detail/2` and
  `agent_detail_from/2` re-export this module so callers use the public API
  unchanged.
  """

  alias Kanban.Agents
  alias Kanban.Agents.Event
  alias Kanban.Agents.Events
  alias Kanban.Agents.Metrics

  # Maximum number of derived events surfaced in a single agent's drill-down,
  # newest first.
  @agent_detail_activity_limit 20

  @doc """
  Builds the drill-down from an already-fetched task list for either an agent
  identity `{name, owner_key}` (per-human) or a bare `name` (pooled), returning
  the detail map or `nil` for an unknown agent. See `Kanban.Agents.agent_detail/2`
  for the full map shape.
  """
  @spec from_tasks([Kanban.Tasks.Task.t()], {String.t(), String.t()} | String.t()) ::
          %{
            name: String.t(),
            current_task: %{identifier: String.t(), title: String.t()} | nil,
            claims: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            failures: [%{identifier: String.t(), title: String.t(), at: DateTime.t()}],
            recent_activity: [Event.t()],
            activity_series: [%{date: Date.t(), count: non_neg_integer()}],
            outcome: %{
              approved: non_neg_integer(),
              rejected: non_neg_integer(),
              in_progress: non_neg_integer(),
              success_rate: float()
            }
          }
          | nil
  def from_tasks(tasks, {name, _owner_key} = identity),
    do: build_detail(Agents.filter_by_identity(tasks, identity), name)

  def from_tasks(tasks, name) when is_binary(name),
    do: build_detail(filter_by_agent_name(tasks, name), name)

  defp build_detail([], _name), do: nil

  defp build_detail(own_tasks, name) do
    %{
      name: name,
      current_task: Agents.current_task(own_tasks),
      claims: claim_history(own_tasks, name),
      failures: failures(own_tasks),
      recent_activity: agent_events(own_tasks, name),
      activity_series: agent_activity_series(own_tasks),
      outcome: agent_outcome(own_tasks)
    }
  end

  # The agent's daily completion counts over the shared trend window, as a
  # `[%{date, count}]` series — the same shape and binning the page-level
  # Delivery-trends band uses, so the per-agent sparkline reads consistently.
  defp agent_activity_series(own_tasks) do
    own_tasks
    |> Metrics.throughput_trends_from(Metrics.default_trend_days())
    |> Map.fetch!(:series)
  end

  # Lifetime outcome breakdown for the success donut: approved/rejected/
  # in-progress counts plus the approved-share ratio. `success_rate/1` already
  # guards the zero-reviewed case, so a no-activity agent yields 0.0 (never an
  # ArithmeticError).
  defp agent_outcome(own_tasks) do
    %{
      approved: Enum.count(own_tasks, &(&1.review_status == :approved)),
      rejected: Enum.count(own_tasks, &(&1.review_status == :rejected)),
      in_progress: Enum.count(own_tasks, &(&1.status == :in_progress)),
      success_rate: Agents.success_rate(own_tasks)
    }
  end

  # Name-only task filter — pools every same-named agent regardless of human.
  # Used only by the back-compat bare-name path; the roster and selection use
  # `Kanban.Agents.filter_by_identity/2` (name + owner) instead.
  defp filter_by_agent_name(tasks, name) do
    Enum.filter(tasks, fn t ->
      t.created_by_agent == name or t.completed_by_agent == name
    end)
  end

  # Tasks this agent claimed (claim actor matches and a claim timestamp exists),
  # newest first. Mirrors `Events.claim_actor/1`'s completer-then-creator
  # precedence so the history reflects the agent that worked the task.
  defp claim_history(tasks, name) do
    tasks
    |> Enum.filter(&(not is_nil(&1.claimed_at) and Events.claim_actor(&1) == name))
    |> Enum.map(&task_ref(&1, &1.claimed_at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # Tasks whose review was rejected, newest first by review time. A rejected
  # task always carries a `reviewed_at` (the review changeset requires it).
  defp failures(tasks) do
    tasks
    |> Enum.filter(&(&1.review_status == :rejected))
    |> Enum.map(&task_ref(&1, &1.reviewed_at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # A lightweight task reference for the drill-down lists: identifier, title,
  # and the relevant timestamp coerced to a DateTime.
  defp task_ref(task, at) do
    %{identifier: task.identifier, title: task.title, at: Events.to_datetime(at)}
  end

  # The agent's own derived events (create/claim/complete/review), newest first,
  # capped at @agent_detail_activity_limit. Reuses `Events.events_for/1` so the
  # event shape matches the activity feed exactly.
  defp agent_events(tasks, name) do
    tasks
    |> Enum.flat_map(&Events.events_for/1)
    |> Enum.filter(&(&1.actor == name))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(@agent_detail_activity_limit)
  end
end
