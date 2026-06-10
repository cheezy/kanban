defmodule Kanban.Agents do
  @moduledoc """
  Derives AI agent state from existing Task records.

  This is a read-only context. It performs no writes and persists no Agent
  or Event records. All derived data comes from existing fields on
  `Kanban.Tasks.Task` — `created_by_agent`, `completed_by_agent`,
  `claimed_at`, `completed_at`, `reviewed_at`, `inserted_at`,
  `review_status`, `status`, and `time_spent_minutes`.

  ## Options

  All public functions accept a keyword list of opts:

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. When provided, results
      are filtered to tasks on boards the scoped user can access via
      `Kanban.Boards.BoardUser` membership. When `nil` (the default), all
      tasks are considered.
    * `:limit` — for `recent_activity/1`, maximum number of events to
      return. Defaults to `50`. Ignored by the other functions.
  """

  import Ecto.Query, warn: false

  alias Kanban.Agents.Agent
  alias Kanban.Agents.Event
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @default_event_limit 50

  @doc """
  Returns the list of agents derived from Task records.

  An agent is any distinct non-nil value of `completed_by_agent` or
  `created_by_agent` across the visible Task set. The returned list is
  ordered by name.
  """
  @spec list_agents(keyword()) :: [Agent.t()]
  def list_agents(opts \\ []) do
    tasks = fetch_tasks(opts)
    today = Date.utc_today()

    tasks
    |> distinct_agent_names()
    |> Enum.sort()
    |> Enum.map(&build_agent(&1, tasks, today))
  end

  @doc """
  Returns a chronological list of derived activity events.

  Events are synthesized from Task timestamps and returned in descending
  order, capped at the `:limit` option (default `#{@default_event_limit}`).
  """
  @spec recent_activity(keyword()) :: [Event.t()]
  def recent_activity(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_event_limit)

    opts
    |> fetch_tasks()
    |> Enum.flat_map(&events_for/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Returns aggregate header counters for the Agents view.

  The returned map contains:

    * `:claimed_today` — count of tasks whose `claimed_at` falls on the
      current UTC date
    * `:completed_today` — count of tasks whose `completed_at` falls on
      the current UTC date
    * `:approved_today` — count of tasks whose `reviewed_at` falls on the
      current UTC date with `review_status` `:approved`
    * `:avg_cycle_minutes` — average `time_spent_minutes` across completed
      tasks where the value is set, or `0` when no qualifying tasks exist
  """
  @spec header_stats(keyword()) :: %{
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats(opts \\ []) do
    tasks = fetch_tasks(opts)
    today = Date.utc_today()

    %{
      claimed_today: count_on_day(tasks, :claimed_at, today),
      completed_today: count_on_day(tasks, :completed_at, today),
      approved_today: count_approved_on(tasks, today),
      avg_cycle_minutes: avg_cycle_minutes(tasks)
    }
  end

  # --- Query helpers ---------------------------------------------------------

  defp fetch_tasks(opts) do
    Task
    |> where([t], t.type != ^:goal)
    |> BoardScope.apply_board_scope_with_column_join(Keyword.get(opts, :scope))
    |> Repo.all()
  end

  # --- list_agents/1 ---------------------------------------------------------

  defp distinct_agent_names(tasks) do
    tasks
    |> Enum.flat_map(fn t -> [t.created_by_agent, t.completed_by_agent] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_agent(name, tasks, today) do
    own_tasks = filter_by_agent(tasks, name)

    %Agent{
      name: name,
      status: infer_status(own_tasks),
      current_task: current_task(own_tasks),
      capabilities: [],
      today: count_completed_on_day(own_tasks, today),
      last_7d: count_completed_within(own_tasks, today, 7),
      success_rate: success_rate(own_tasks),
      claim_count: Enum.count(own_tasks, &(not is_nil(&1.claimed_at)))
    }
  end

  defp filter_by_agent(tasks, name) do
    Enum.filter(tasks, fn t ->
      t.created_by_agent == name or t.completed_by_agent == name
    end)
  end

  defp infer_status(tasks) do
    cond do
      Enum.any?(tasks, &(&1.status == :in_progress)) -> :working
      awaiting_review?(tasks) -> :waiting
      true -> :idle
    end
  end

  defp awaiting_review?(tasks) do
    case most_recent_task(tasks) do
      nil ->
        false

      task ->
        task.status == :completed and task.needs_review == true and
          is_nil(task.reviewed_at)
    end
  end

  defp most_recent_task([]), do: nil

  defp most_recent_task(tasks) do
    Enum.max_by(tasks, &task_recency/1, NaiveDateTime)
  end

  defp task_recency(task) do
    [task.completed_at, task.reviewed_at, task.claimed_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_naive/1)
    |> case do
      [] -> task.inserted_at
      stamps -> Enum.max(stamps, NaiveDateTime)
    end
  end

  defp to_naive(%NaiveDateTime{} = ndt), do: ndt
  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)

  defp current_task(tasks) do
    case Enum.find(tasks, &(&1.status == :in_progress)) do
      nil -> nil
      task -> %{identifier: task.identifier, title: task.title}
    end
  end

  defp count_completed_on_day(tasks, date) do
    Enum.count(tasks, &completed_on?(&1, date))
  end

  defp count_completed_within(tasks, today, days) do
    earliest = Date.add(today, -(days - 1))

    Enum.count(tasks, fn task ->
      case task.completed_at do
        nil -> false
        %DateTime{} = dt -> Date.compare(DateTime.to_date(dt), earliest) != :lt
      end
    end)
  end

  defp success_rate(tasks) do
    approved = Enum.count(tasks, &(&1.review_status == :approved))
    rejected = Enum.count(tasks, &(&1.review_status == :rejected))

    case approved + rejected do
      0 -> 0.0
      total -> approved / total
    end
  end

  # --- header_stats/1 --------------------------------------------------------

  defp count_on_day(tasks, field, date) do
    Enum.count(tasks, fn task ->
      case Map.get(task, field) do
        nil -> false
        %DateTime{} = dt -> DateTime.to_date(dt) == date
      end
    end)
  end

  defp count_approved_on(tasks, date) do
    Enum.count(tasks, fn task ->
      task.review_status == :approved and not is_nil(task.reviewed_at) and
        DateTime.to_date(task.reviewed_at) == date
    end)
  end

  defp avg_cycle_minutes(tasks) do
    minutes =
      tasks
      |> Enum.filter(&(not is_nil(&1.completed_at) and is_integer(&1.time_spent_minutes)))
      |> Enum.map(& &1.time_spent_minutes)

    case minutes do
      [] -> 0.0
      list -> Enum.sum(list) / length(list)
    end
  end

  defp completed_on?(%{completed_at: %DateTime{} = dt}, date), do: DateTime.to_date(dt) == date
  defp completed_on?(_task, _date), do: false

  # --- recent_activity/1 -----------------------------------------------------

  defp events_for(task) do
    [
      build_event(:create, task.created_by_agent, task, task.inserted_at),
      build_event(:claim, task.created_by_agent, task, task.claimed_at),
      build_event(:complete, task.completed_by_agent, task, task.completed_at),
      build_event(:review, task.completed_by_agent, task, task.reviewed_at)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_event(_kind, _actor, _task, nil), do: nil

  defp build_event(kind, actor, task, at) do
    %Event{
      kind: kind,
      actor: actor,
      identifier: task.identifier,
      title: task.title,
      at: to_datetime(at),
      cycle_time_minutes: cycle_time_for(kind, task)
    }
  end

  defp cycle_time_for(:complete, %{time_spent_minutes: minutes}) when is_integer(minutes),
    do: minutes

  defp cycle_time_for(_kind, _task), do: nil

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
