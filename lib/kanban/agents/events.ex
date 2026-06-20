defmodule Kanban.Agents.Events do
  @moduledoc """
  Synthesizes the read-only activity-event stream from Task timestamps.

  Extracted from `Kanban.Agents` so event derivation lives behind a single-
  responsibility boundary (mirroring `Kanban.Agents.Metrics`). Each task is
  turned into its `:create` / `:claim` / `:complete` / `:review` `Event`s;
  owner resolution and the shared task set come from `Kanban.Agents`.

  `Kanban.Agents.recent_activity/1` and `recent_activity_from/2` re-export this
  module so callers keep using the `Kanban.Agents` public API unchanged.
  """

  alias Kanban.Agents
  alias Kanban.Agents.Event

  @doc """
  Synthesizes the descending activity-event list from an already-fetched task
  list, capped at `limit`. The cap is applied in Elixir (after sorting), never
  pushed into the DB, so the shared task fetch feeds this without a new query.
  """
  @spec recent_activity_from([Kanban.Tasks.Task.t()], non_neg_integer()) :: [Event.t()]
  def recent_activity_from(tasks, limit) do
    tasks
    |> Enum.flat_map(&events_for/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc false
  # Exposed for `Kanban.Agents.Detail`, which filters these to one agent's
  # events. The four lifecycle events a task can contribute, nils removed.
  def events_for(task) do
    claim_owner_map = task |> claim_owner() |> Agents.to_owner_map()

    [
      build_event(
        :create,
        task.created_by_agent,
        Agents.to_owner_map(task.created_by),
        task,
        task.inserted_at
      ),
      build_event(
        :claim,
        claim_actor(task),
        claim_owner_map,
        task,
        task.claimed_at
      ),
      build_event(
        :complete,
        task.completed_by_agent,
        Agents.to_owner_map(task.completed_by),
        task,
        task.completed_at
      ),
      build_event(
        :review,
        task.completed_by_agent,
        Agents.to_owner_map(task.completed_by),
        task,
        task.reviewed_at
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  # The agent associated with a claim. In Stride's single-claim model the agent
  # that completes a task is the one that claimed and worked it, so prefer
  # `completed_by_agent`; fall back to the creating agent, then to nil (the feed
  # renders nil as a neutral fallback avatar). This keeps the Claims/All views
  # showing the working agent instead of a blank, without inventing a name.
  # Exposed for `Kanban.Agents.Detail`'s claim-history derivation.
  def claim_actor(task), do: task.completed_by_agent || task.created_by_agent

  # The User behind a claim event, mirroring claim_actor's precedence: prefer
  # the completer, fall back to the creator. Uses the same preloaded
  # created_by/completed_by associations as the roster, so no extra query.
  defp claim_owner(task), do: task.completed_by || task.created_by

  defp build_event(_kind, _actor, _owner, _task, nil), do: nil

  defp build_event(kind, actor, owner, task, at) do
    %Event{
      kind: kind,
      actor: actor,
      owner: owner,
      identifier: task.identifier,
      title: task.title,
      at: to_datetime(at),
      cycle_time_minutes: cycle_time_for(kind, task)
    }
  end

  defp cycle_time_for(:complete, %{time_spent_minutes: minutes}) when is_integer(minutes),
    do: minutes

  defp cycle_time_for(_kind, _task), do: nil

  @doc false
  # Coerces a Naive/DateTime stamp to a UTC `DateTime`. Exposed for
  # `Kanban.Agents.Detail`, whose claim/failure refs reuse the same coercion.
  def to_datetime(%DateTime{} = dt), do: dt
  def to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
