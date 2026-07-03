defmodule Kanban.Metrics.TaskQueries do
  @moduledoc """
  Read-only query builders for the completed-task rows the cycle time and
  lead time metrics views render.

  Extracted from `KanbanWeb.MetricsLive.CycleTime` and
  `KanbanWeb.MetricsLive.LeadTime` so the LiveViews hold no Ecto queries
  (per the project rule against database queries in the web layer). Each
  function returns display-shaped row maps whose keys the metrics templates
  read directly, so the returned map shape must not change.

  ## Options

  Both public functions accept the same keyword options, built by
  `KanbanWeb.MetricsLive.Base.build_loader_opts/1`:

    * `:time_range` - one of `:today`, `:last_7_days`, `:last_30_days`
      (default), `:last_90_days`, or `:all_time`. Bounds `completed_at`.
    * `:timezone` - IANA timezone string (default `"Etc/UTC"`) used to anchor
      the time-range window to the viewer's local calendar day.
    * `:agent_name` - when present, restricts rows to that `completed_by_agent`.

  The query functions take a `board_id` already authorized by the caller and
  never widen access beyond that single board.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Timezone

  # Days back from "today" for each fixed range; `:all_time` is handled
  # separately with a sentinel. Mirrors the window the metrics views used
  # before these queries moved out of the web layer.
  @date_range_days %{today: 0, last_7_days: 6, last_30_days: 29, last_90_days: 89}

  @doc """
  Returns completed-task rows for the cycle time view, newest completion first.

  Cycle time spans from when work started to when it completed; the start
  marker depends on the board type:

    * AI-optimized boards use the task's `claimed_at`. The `:agent_name`
      option, when present, filters these rows.
    * Regular boards derive the start from the earliest `:move` event in the
      task history (`min(inserted_at)`), so tasks with no move event are
      excluded. Regular boards carry no agent, so `:agent_name` is ignored.

  ## Examples

      iex> get_cycle_time_tasks(board_id, time_range: :last_7_days)
      [%{identifier: "W1", claimed_at: ~U[...], cycle_time_seconds: 3600.0, ...}]

  """
  def get_cycle_time_tasks(board_id, opts \\ []) do
    if board_ai_optimized?(board_id) do
      cycle_time_tasks_ai(board_id, opts)
    else
      cycle_time_tasks_regular(board_id, opts)
    end
  end

  @doc """
  Returns completed-task rows for the lead time view, newest completion first.

  Lead time always spans from task creation (`inserted_at`) to completion,
  regardless of board type. When `:agent_name` is present the rows are
  restricted to that `completed_by_agent` on every board.

  ## Examples

      iex> get_lead_time_tasks(board_id, time_range: :last_30_days)
      [%{identifier: "W1", inserted_at: ~N[...], lead_time_seconds: 7200.0, ...}]

  """
  def get_lead_time_tasks(board_id, opts \\ []) do
    {start_date, agent_name} = window(opts)

    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      lead_time_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, t.inserted_at)
    })
    |> maybe_filter_by_agent(agent_name)
    |> Repo.all()
  end

  # AI-optimized boards record `claimed_at` when an agent starts work, so cycle
  # time is `completed_at - claimed_at`. Rows without a `claimed_at` are excluded.
  defp cycle_time_tasks_ai(board_id, opts) do
    {start_date, agent_name} = window(opts)

    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], not is_nil(t.claimed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      claimed_at: t.claimed_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      cycle_time_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, t.claimed_at)
    })
    |> maybe_filter_by_agent(agent_name)
    |> Repo.all()
  end

  # Regular boards have no `claimed_at`; work "starts" at the first column move,
  # so cycle time is `completed_at - min(move.inserted_at)`. The inner join to
  # the first-move subquery excludes tasks that were never moved. No agent
  # filter here — regular boards do not carry an agent.
  defp cycle_time_tasks_regular(board_id, opts) do
    {start_date, _agent_name} = window(opts)

    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t], fm in subquery(first_move_subquery()), on: fm.task_id == t.id)
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t, _c, fm], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      claimed_at: fm.started_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      cycle_time_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, fm.started_at)
    })
    |> Repo.all()
  end

  # The earliest `:move` event per task marks when work started on a regular
  # board. Grouping by `task_id` collapses `min(inserted_at)` to one row per task.
  defp first_move_subquery do
    from th in TaskHistory,
      where: th.type == :move,
      group_by: th.task_id,
      select: %{task_id: th.task_id, started_at: min(th.inserted_at)}
  end

  # Parses the shared window opts once: the `completed_at` lower bound and the
  # optional agent-name filter. `:exclude_weekends` is intentionally ignored
  # here — only the stats functions in `Kanban.Metrics` honor it.
  defp window(opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    agent_name = Keyword.get(opts, :agent_name)
    {start_date(time_range, timezone), agent_name}
  end

  defp maybe_filter_by_agent(query, nil), do: query

  defp maybe_filter_by_agent(query, agent_name) do
    where(query, [t], t.completed_by_agent == ^agent_name)
  end

  defp board_ai_optimized?(board_id) do
    Repo.get!(Board, board_id).ai_optimized_board
  end

  # The UTC instant of local midnight at the start of the requested window,
  # anchored to `timezone` (default "Etc/UTC" reproduces the prior UTC-midnight
  # behavior). `:all_time` keeps the fixed 2020 sentinel the metrics views used.
  defp start_date(:all_time, _timezone), do: ~U[2020-01-01 00:00:00Z]

  defp start_date(time_range, timezone) do
    days = Map.get(@date_range_days, time_range, 29)

    timezone
    |> Timezone.local_today()
    |> Date.add(-days)
    |> Timezone.start_of_local_day(timezone)
  end
end
