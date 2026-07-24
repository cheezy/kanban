defmodule Kanban.Boards.Metrics do
  @moduledoc """
  Aggregate reads behind the Boards index pulse cards, the single-board
  header, and the workspace-wide rollups.

  Every function here takes an **already-scoped** list of board ids (or a
  list of boards a scoped read produced). Scoping is the facade's job —
  `Kanban.Boards.list_boards/1` decides which boards a user may see, and
  nothing in this module filters by user. Never call these with ids that
  did not come from a scoped read.

  Exposed through the `Kanban.Boards` facade the same way
  `Kanban.Boards.Membership` is: call `Boards.list_boards_with_metrics/2`,
  `Boards.workspace_metrics/2`, `Boards.list_workspace_members/2` and
  friends rather than reaching into this module directly. The facade owns
  the public documentation for those entry points.

  Split out of `Kanban.Boards` because the aggregate-query surface is a
  distinct concern from board CRUD and access control, per the module
  design guidance in `AGENTS.md`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  alias KanbanWeb.AvatarPalette

  @pulse_window_days 14
  @open_columns ~w(Backlog Ready)
  @doing_column "Doing"
  @review_column "Review"
  @done_column "Done"

  @doc """
  Returns `%{board_id => metrics_map}` for the given boards.

  Issues a fixed number of aggregate queries — one per metric family, all
  grouped by `board_id` — so cost stays constant regardless of how many
  boards are passed. See `Kanban.Boards.list_boards_with_metrics/2` for
  the key-by-key description of the metrics map.
  """
  def build_metrics(board_ids, now) do
    today = DateTime.to_date(now)
    cutoff_dt = pulse_cutoff(now)

    aggregates = %{
      column_counts: column_counts_by_board(board_ids),
      pulse_rows: pulse_rows_by_board(board_ids, cutoff_dt),
      throughput: throughput_by_board(board_ids, cutoff_dt),
      active_agents: active_agents_by_board(board_ids, cutoff_dt),
      last_activity: last_activity_by_board(board_ids),
      pulse_dates: pulse_date_range(today)
    }

    Map.new(board_ids, &{&1, metrics_for_board(&1, aggregates)})
  end

  @doc """
  The all-zero metrics map, for boards `build_metrics/2` returned no row
  for. `now` anchors the `:pulse_14d` array length.
  """
  def empty_metrics(now) do
    %{
      open: 0,
      doing: 0,
      review: 0,
      done: 0,
      throughput_14d: 0,
      pulse_14d: zero_pulse(now),
      active_agents_14d: 0,
      last_activity_at: nil
    }
  end

  @doc """
  Returns `%{board_id => [member_map]}` built from the users on each
  board's `board_users` join. See `Kanban.Boards.list_board_members/1`
  for the member shape and why `:user_id` rides along.

  Returns all members and lets `KanbanWeb.Avatar.avatar_stack/1` handle
  the five-visible truncation.
  """
  def members_by_board(board_ids) do
    BoardUser
    |> join(:inner, [bu], u in User, on: u.id == bu.user_id)
    |> where([bu], bu.board_id in ^board_ids)
    |> select([bu, u], {bu.board_id, u.id, u.name, u.email})
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      {board_id, user_id, name, email} = row

      member = %{
        kind: :human,
        name: member_display_name(name, email),
        palette: AvatarPalette.for_human(user_id),
        user_id: user_id
      }

      Map.update(acc, board_id, [member], &(&1 ++ [member]))
    end)
  end

  @doc """
  Folds a list of boards carrying `:metrics` into workspace-wide
  `%{open:, doing:, review:, done:}` totals. Pure — issues no query, and
  performs no scope filtering. See `Kanban.Boards.workspace_metrics_from/1`.
  """
  def workspace_totals(boards) when is_list(boards) do
    Enum.reduce(boards, %{open: 0, doing: 0, review: 0, done: 0}, fn board, totals ->
      metrics = board_metrics_map(board)

      Map.new(totals, fn {bucket, running} ->
        {bucket, running + Map.get(metrics, bucket, 0)}
      end)
    end)
  end

  defp board_metrics_map(%{metrics: metrics}) when is_map(metrics), do: metrics
  defp board_metrics_map(_board), do: %{}

  @doc """
  Returns the deduplicated, sorted people-and-agents roster across the
  given boards. See `Kanban.Boards.list_workspace_members/2` for the
  shape, the dedup rules, and the definition of "agent".

  Costs two queries regardless of board count.
  """
  def workspace_members(board_ids, now) do
    cutoff_dt = pulse_cutoff(now)

    humans =
      board_ids
      |> members_by_board()
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq_by(& &1.user_id)

    agents =
      board_ids
      |> agent_names_by_boards(cutoff_dt)
      |> Enum.map(&%{kind: :agent, name: &1, palette: AvatarPalette.for_agent(&1)})

    Enum.sort_by(humans ++ agents, &member_sort_key/1)
  end

  defp member_sort_key(%{kind: :human, name: name, user_id: user_id}),
    do: {0, String.downcase(name), user_id}

  defp member_sort_key(%{kind: :agent, name: name}), do: {1, String.downcase(name), 0}

  defp member_display_name(name, email) when is_binary(name) do
    case String.trim(name) do
      "" -> email_local_part(email)
      trimmed -> trimmed
    end
  end

  defp member_display_name(_name, email), do: email_local_part(email)

  defp email_local_part(email) when is_binary(email) do
    email |> String.split("@", parts: 2) |> List.first()
  end

  defp email_local_part(_), do: "?"

  defp metrics_for_board(board_id, agg) do
    %{
      open: Map.get(agg.column_counts, {board_id, :open}, 0),
      doing: Map.get(agg.column_counts, {board_id, :doing}, 0),
      review: Map.get(agg.column_counts, {board_id, :review}, 0),
      done: Map.get(agg.column_counts, {board_id, :done}, 0),
      throughput_14d: Map.get(agg.throughput, board_id, 0),
      pulse_14d: build_pulse_array(Map.get(agg.pulse_rows, board_id, %{}), agg.pulse_dates),
      active_agents_14d: Map.get(agg.active_agents, board_id, 0),
      last_activity_at: Map.get(agg.last_activity, board_id)
    }
  end

  defp zero_pulse(now) do
    now |> DateTime.to_date() |> pulse_date_range() |> Enum.map(fn _ -> 0 end)
  end

  # Start of the @pulse_window_days window that every 14-day metric shares.
  # `workspace_members/2` calls this too, so the workspace agent roster can
  # never drift from the per-board `:active_agents_14d` count.
  defp pulse_cutoff(now) do
    now
    |> DateTime.to_date()
    |> Date.add(-(@pulse_window_days - 1))
    |> DateTime.new!(~T[00:00:00])
  end

  defp pulse_date_range(today) do
    today
    |> Date.add(-(@pulse_window_days - 1))
    |> Date.range(today)
    |> Enum.to_list()
  end

  defp build_pulse_array(counts_by_date, pulse_dates) do
    Enum.map(pulse_dates, fn date -> Map.get(counts_by_date, date, 0) end)
  end

  # Returns %{{board_id, :open | :doing | :review | :done} => count}.
  # Archived tasks (those with a non-nil `archived_at`) and goal-type tasks
  # are excluded so the board card stats reflect actionable work only.
  defp column_counts_by_board(board_ids) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t, _c], is_nil(t.archived_at))
    |> where([t, _c], t.type != :goal)
    |> where(
      [_t, c],
      c.name in ^@open_columns or c.name in [@doing_column, @review_column, @done_column]
    )
    |> group_by([_t, c], [c.board_id, c.name])
    |> select([_t, c], {c.board_id, c.name, count()})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, name, count}, acc ->
      # Backlog and Ready both bucket to :open, so accumulate when two
      # column names roll up to the same bucket on the same board.
      Map.update(acc, {board_id, bucket_for(name)}, count, &(&1 + count))
    end)
  end

  defp bucket_for(name) when name in @open_columns, do: :open
  defp bucket_for(@doing_column), do: :doing
  defp bucket_for(@review_column), do: :review
  defp bucket_for(@done_column), do: :done

  # Returns %{board_id => %{Date => count}}.
  defp pulse_rows_by_board(board_ids, cutoff_dt) do
    board_ids
    |> pulse_query(cutoff_dt)
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, date, count}, acc ->
      Map.update(acc, board_id, %{date => count}, &Map.put(&1, date, count))
    end)
  end

  defp pulse_query(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
    |> group_by([t, c], [c.board_id, fragment("DATE(?)", t.completed_at)])
    |> select([t, c], {c.board_id, fragment("DATE(?)", t.completed_at), count(t.id)})
  end

  # Returns %{board_id => total_count}.
  defp throughput_by_board(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Returns %{board_id => distinct_agent_count}.
  defp active_agents_by_board(board_ids, cutoff_dt) do
    board_ids
    |> active_agents_query(cutoff_dt)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, count(t.completed_by_agent, :distinct)})
    |> Repo.all()
    |> Map.new()
  end

  # Returns the distinct agent names across ALL the given boards — the
  # roster behind the per-board count `active_agents_by_board/2` returns.
  # One query, no grouping, so the cost does not grow with board count.
  defp agent_names_by_boards(board_ids, cutoff_dt) do
    board_ids
    |> active_agents_query(cutoff_dt)
    |> distinct(true)
    |> select([t], t.completed_by_agent)
    |> Repo.all()
  end

  # The shared "an agent did work here recently" predicate. Blank names are
  # excluded: `Task` neither trims nor requires `completed_by_agent`, and a
  # blank string would surface as a nameless ghost avatar. `btrim` catches
  # whitespace-only names too, which a bare `<> ''` comparison would let
  # through.
  defp active_agents_query(board_ids, cutoff_dt) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t], not is_nil(t.completed_by_agent))
    |> where([t], fragment("btrim(?) <> ''", t.completed_by_agent))
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^cutoff_dt)
  end

  # Returns %{board_id => DateTime}. Picks the later of max(claimed_at)
  # and max(completed_at). Boards with neither timestamp anywhere are
  # absent from the map; the caller defaults them to nil.
  defp last_activity_by_board(board_ids) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids)
    |> group_by([_t, c], c.board_id)
    |> select([t, c], {c.board_id, max(t.claimed_at), max(t.completed_at)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {board_id, max_claimed, max_completed}, acc ->
      case latest(max_claimed, max_completed) do
        nil -> acc
        dt -> Map.put(acc, board_id, dt)
      end
    end)
  end

  defp latest(nil, nil), do: nil
  defp latest(nil, dt), do: dt
  defp latest(dt, nil), do: dt
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
