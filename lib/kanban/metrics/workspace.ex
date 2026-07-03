defmodule Kanban.Metrics.Workspace do
  @moduledoc """
  Workspace-level (cross-board) metric reads that back the `/metrics` page.

  Extracted from `Kanban.Metrics` (W1439) to keep that context under the
  module-size guideline. These functions aggregate across every board the
  scoped user can access, rather than operating on a single board id like the
  board-level reads in `Kanban.Metrics`.

  Five workspace-scoped functions back the `/metrics` page and aggregate
  across every board the scoped user can access:

    * `workspace_kpis/1` — KPI strip with delta-vs-previous-14-day percentages
    * `cycle_time_daily/1` — 14 daily median cycle times
    * `throughput_daily/1` — 14 daily completion counts
    * `agent_leaderboard/1` — top 6 contributors (agents before humans)
    * `cumulative_flow/1` — 14 daily snapshots across 5 derived states

  All five accept `opts` with `:scope` and route through
  `Kanban.Boards.list_boards(scope.user)` to derive the visible board id
  set. A `nil` scope or a scope with `nil` user returns the empty/zero
  shape — never raises.

  ### Cumulative-flow approximation

  No daily snapshot table exists. Each per-day snapshot is reconstructed
  by classifying every visible task by its timestamp state at end-of-day:

  | Bucket    | Rule (at end-of-day D) |
  |-----------|-------------------------|
  | `:backlog`  | `inserted_at <= D` and `claimed_at IS NULL` |
  | `:ready`    | always 0 (no schema distinction between :open and "ready"; reserved for a future snapshot table) |
  | `:doing`    | `claimed_at <= D` and (`completed_at` is `nil` or `> D`) |
  | `:review`   | `completed_at <= D`, `needs_review`, and (`reviewed_at` is `nil` or `> D`) |
  | `:done`     | `reviewed_at <= D` OR (`completed_at <= D` and not `needs_review`) |

  Archived tasks (`archived_at <= D`) are excluded from every bucket.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Metrics.Calculations
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @workspace_window_days 14
  @allowed_window_days [7, 14, 30, 90]
  @workspace_agent_leaderboard_limit 6

  @doc """
  Returns the workspace KPI strip — median cycle time, p75 lead time,
  per-day throughput, and median review wait — with delta percentages
  vs the previous equal-length window.

  Returns the zero map when the scoped user has no boards.

  ## Options

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. When `nil` or its user
      is `nil`, the function returns the zero map.
    * `:window_days` — the trailing window length in days. Allow-listed
      to #{inspect(@allowed_window_days)}; any other value (including
      `nil` or an absent option) falls back to #{@workspace_window_days}.
      The previous window used for the delta percentages always matches
      the resolved window length.
    * `:timezone` — the viewer's IANA timezone, accepted by every
      workspace read for local-day bucketing. Defaults to `"Etc/UTC"`
      when omitted or unknown; the day-boundary conversion that consumes
      it is layered on in later work, so the option is currently a
      no-op pass-through.
  """
  @spec workspace_kpis(keyword()) :: %{
          cycle_time_median_minutes: non_neg_integer(),
          cycle_time_delta_pct: float(),
          lead_time_p75_minutes: non_neg_integer(),
          lead_time_delta_pct: float(),
          throughput_per_day: float(),
          throughput_delta_pct: float(),
          review_wait_minutes: non_neg_integer(),
          review_wait_delta_pct: float()
        }
  def workspace_kpis(opts \\ []) do
    case scoped_board_ids(opts) do
      [] ->
        zero_kpis()

      board_ids ->
        window_days = resolve_window_days(opts)
        timezone = Keyword.get(opts, :timezone, "Etc/UTC")
        now = DateTime.utc_now()
        current_start = local_day_start(window_days - 1, timezone)
        previous_start = local_day_start(2 * window_days - 1, timezone)

        current = completed_tasks_in_window(board_ids, current_start, now)
        previous = completed_tasks_in_window(board_ids, previous_start, current_start)

        build_kpis(current, previous, window_days)
    end
  end

  @doc """
  Returns the most recent days of overall median cycle time.

  Each entry is `%{date: Date.t(), minutes: integer()}` ordered
  oldest-to-newest, where `minutes` is the median cycle time across all
  completed tasks that day. Days with no completed tasks render zero.
  The series length is the resolved `:window_days` option (default
  #{@workspace_window_days}).
  """
  @spec cycle_time_daily(keyword()) :: [%{date: Date.t(), minutes: non_neg_integer()}]
  def cycle_time_daily(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case scoped_board_ids(opts) do
      [] -> empty_day_series(&zero_cycle_entry/1, window_days, timezone)
      board_ids -> build_cycle_time_daily(board_ids, window_days, timezone)
    end
  end

  defp zero_cycle_entry(date), do: %{date: date, minutes: 0}

  defp build_cycle_time_daily(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    window_start = local_day_start(window_days - 1, timezone)

    per_day =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> bucket_cycle_minutes(timezone)

    window_days
    |> day_range(timezone)
    |> Enum.map(&cycle_entry_for(&1, per_day))
  end

  defp cycle_entry_for(date, per_day) do
    per_day
    |> Map.get(date, %{minutes: 0})
    |> Map.put(:date, date)
  end

  defp bucket_cycle_minutes(tasks, timezone) do
    tasks
    |> Enum.group_by(&completed_on_date(&1, timezone))
    |> Map.new(&cycle_bucket_entry/1)
  end

  defp cycle_bucket_entry({date, tasks}) do
    {date, %{minutes: median_cycle_minutes(tasks)}}
  end

  @doc """
  Returns the most recent daily completion counts, oldest-to-newest.

  The series length is the resolved `:window_days` option
  (default #{@workspace_window_days}).
  """
  @spec throughput_daily(keyword()) :: [non_neg_integer()]
  def throughput_daily(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case scoped_board_ids(opts) do
      [] -> List.duplicate(0, window_days)
      board_ids -> build_throughput_daily(board_ids, window_days, timezone)
    end
  end

  defp build_throughput_daily(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    window_start = local_day_start(window_days - 1, timezone)

    counts =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> Enum.frequencies_by(&completed_on_date(&1, timezone))

    window_days
    |> day_range(timezone)
    |> Enum.map(&Map.get(counts, &1, 0))
  end

  @doc """
  Returns up to six contributors (agents before humans, descending by
  completed count) for the trailing window (the resolved `:window_days`
  option, default #{@workspace_window_days}).

  Each entry is `%{name: String.t(), kind: :agent | :human,
  completed: non_neg_integer(), success_pct: float()}`. `success_pct`
  is the fraction of the contributor's window completions that were
  either approved (`review_status == :approved`) or did not need
  review at all, expressed as a percent.
  """
  @spec agent_leaderboard(keyword()) :: [
          %{
            name: String.t(),
            kind: :agent | :human,
            completed: non_neg_integer(),
            success_pct: float()
          }
        ]
  def agent_leaderboard(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case scoped_board_ids(opts) do
      [] -> []
      board_ids -> build_agent_leaderboard(board_ids, window_days, timezone)
    end
  end

  defp build_agent_leaderboard(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    window_start = local_day_start(window_days - 1, timezone)

    tasks =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> Repo.preload(:completed_by)

    agents = agent_leaderboard_rows(tasks)
    humans = human_leaderboard_rows(tasks)

    Enum.take(agents ++ humans, @workspace_agent_leaderboard_limit)
  end

  defp agent_leaderboard_rows(tasks) do
    tasks
    |> Enum.reject(&is_nil(&1.completed_by_agent))
    |> group_leaderboard(:agent, & &1.completed_by_agent)
  end

  defp human_leaderboard_rows(tasks) do
    tasks
    |> Enum.filter(&human_completion?/1)
    |> group_leaderboard(:human, &human_name/1)
  end

  @doc """
  Returns daily cumulative-flow snapshots, oldest-to-newest. Each
  snapshot has integer counts for `:backlog`, `:ready`, `:doing`,
  `:review`, and `:done`. See the `@moduledoc` for the per-state
  approximation rules. The series length is the resolved `:window_days`
  option (default #{@workspace_window_days}).
  """
  @spec cumulative_flow(keyword()) :: [
          %{
            date: Date.t(),
            backlog: non_neg_integer(),
            ready: non_neg_integer(),
            doing: non_neg_integer(),
            review: non_neg_integer(),
            done: non_neg_integer()
          }
        ]
  def cumulative_flow(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case scoped_board_ids(opts) do
      [] -> empty_day_series(&zero_flow_snapshot/1, window_days, timezone)
      board_ids -> build_cumulative_flow(board_ids, window_days, timezone)
    end
  end

  defp build_cumulative_flow(board_ids, window_days, timezone) do
    tasks = workspace_tasks(board_ids)

    window_days
    |> day_range(timezone)
    |> Enum.map(&cfd_snapshot(tasks, &1, timezone))
  end

  # --- Workspace helpers ----------------------------------------------------

  defp scoped_board_ids(opts) do
    case Keyword.get(opts, :scope) do
      %Scope{user: %{} = user} ->
        user
        |> Boards.list_boards()
        |> Enum.map(& &1.id)
        |> filter_board_ids(Keyword.get(opts, :board_ids))

      _ ->
        []
    end
  end

  # Restrict the visible board ids to an optional client-supplied subset.
  # nil means "no filter" (return all visible ids, unchanged behavior). A list
  # is treated as untrusted input: intersect it with the visible ids so ids the
  # user cannot see are silently dropped. Always returns a plain list of ids.
  defp filter_board_ids(visible_ids, nil), do: visible_ids

  defp filter_board_ids(visible_ids, requested_ids) when is_list(requested_ids) do
    visible_set = MapSet.new(visible_ids)

    requested_ids
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(visible_set, &1))
  end

  # Resolve the trailing window length from an untrusted client option.
  # The value bounds already board-scoped queries, so it is restricted to
  # a fixed allow-list — any unsupported value (including `nil` or an
  # absent option) falls back to the default so a forged number can never
  # force an unbounded or very large scan.
  defp resolve_window_days(opts) do
    case Keyword.get(opts, :window_days) do
      days when days in @allowed_window_days -> days
      _ -> @workspace_window_days
    end
  end

  defp completed_tasks_in_window(board_ids, %DateTime{} = window_start, %DateTime{} = window_end) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t, _c], not is_nil(t.completed_at))
    |> where([t, _c], t.completed_at >= ^window_start)
    |> where([t, _c], t.completed_at <= ^window_end)
    # Goals get a `completed_at` when their last child finishes; exclude them so
    # workspace throughput/cycle-time/leaderboard count only real work, matching
    # every board-level metric query (which all filter `type != :goal`). See D87.
    |> where([t, _c], t.type != ^:goal)
    |> Repo.all()
  end

  # Loads every task across every visible board into memory; `cumulative_flow/1`
  # iterates the result 14 times to bucket per-day snapshots. Acceptable at
  # current workspace sizes — once any workspace exceeds ~10k tasks, push the
  # bucketing into SQL (or project a daily snapshot table) so the LiveView
  # mount stays under its budget. Flagged in W579 reviewer notes.
  defp workspace_tasks(board_ids) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> Repo.all()
  end

  defp zero_kpis do
    %{
      cycle_time_median_minutes: 0,
      cycle_time_delta_pct: 0.0,
      lead_time_p75_minutes: 0,
      lead_time_delta_pct: 0.0,
      throughput_per_day: 0.0,
      throughput_delta_pct: 0.0,
      review_wait_minutes: 0,
      review_wait_delta_pct: 0.0
    }
  end

  defp build_kpis(current, previous, window_days) do
    cycle_current = median_cycle_minutes(current)
    cycle_previous = median_cycle_minutes(previous)

    lead_current = percentile_lead_minutes(current, 75)
    lead_previous = percentile_lead_minutes(previous, 75)

    throughput_current = length(current) / window_days
    throughput_previous = length(previous) / window_days

    review_current = median_review_wait_minutes(current)
    review_previous = median_review_wait_minutes(previous)

    %{
      cycle_time_median_minutes: cycle_current,
      cycle_time_delta_pct: delta_pct(cycle_current, cycle_previous),
      lead_time_p75_minutes: lead_current,
      lead_time_delta_pct: delta_pct(lead_current, lead_previous),
      throughput_per_day: throughput_current,
      throughput_delta_pct: delta_pct(throughput_current, throughput_previous),
      review_wait_minutes: review_current,
      review_wait_delta_pct: delta_pct(review_current, review_previous)
    }
  end

  # Public spec lists delta_pct as a private helper. Implements
  # divide-by-zero safety: a 0 previous window collapses to 0.0%.
  defp delta_pct(_current, previous) when previous == 0 or previous == 0.0, do: 0.0

  defp delta_pct(current, previous) when is_number(current) and is_number(previous) do
    (current - previous) / previous * 100.0
  end

  defp median_cycle_minutes(tasks) do
    tasks
    |> Enum.map(&cycle_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  defp percentile_lead_minutes(tasks, p) do
    tasks
    |> Enum.map(&lead_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.percentile(p)
    |> round_or_zero()
  end

  defp median_review_wait_minutes(tasks) do
    tasks
    |> Enum.map(&review_wait_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  defp cycle_minutes(%{claimed_at: %DateTime{} = c, completed_at: %DateTime{} = d}) do
    DateTime.diff(d, c, :second) |> max(0) |> div(60)
  end

  defp cycle_minutes(_), do: nil

  defp lead_minutes(%{inserted_at: %NaiveDateTime{} = i, completed_at: %DateTime{} = d}) do
    inserted = DateTime.from_naive!(i, "Etc/UTC")
    DateTime.diff(d, inserted, :second) |> max(0) |> div(60)
  end

  defp lead_minutes(_), do: nil

  defp review_wait_minutes(%{
         needs_review: true,
         completed_at: %DateTime{} = c,
         reviewed_at: %DateTime{} = r
       }) do
    DateTime.diff(r, c, :second) |> max(0) |> div(60)
  end

  defp review_wait_minutes(_), do: nil

  defp round_or_zero(nil), do: 0
  defp round_or_zero(value) when is_number(value), do: round(value)

  defp human_completion?(%{completed_by_agent: agent}) when is_binary(agent) and agent != "",
    do: false

  defp human_completion?(%{completed_by_id: id}) when is_integer(id), do: true
  defp human_completion?(_), do: false

  defp human_name(%{completed_by: %{name: name}}) when is_binary(name) and name != "", do: name
  defp human_name(%{completed_by: %{email: email}}) when is_binary(email), do: email
  defp human_name(_), do: "?"

  defp group_leaderboard(tasks, kind, name_fun) do
    tasks
    |> Enum.group_by(name_fun)
    |> Enum.map(fn {name, ts} ->
      total = length(ts)
      success = Enum.count(ts, &successful_completion?/1)

      %{
        name: name,
        kind: kind,
        completed: total,
        success_pct: success_pct(success, total)
      }
    end)
    |> Enum.sort_by(& &1.completed, :desc)
  end

  defp successful_completion?(%{needs_review: false}), do: true
  defp successful_completion?(%{review_status: :approved}), do: true
  defp successful_completion?(_), do: false

  defp success_pct(_success, 0), do: 0.0
  defp success_pct(success, total), do: success / total * 100.0

  defp completed_on_date(%{completed_at: %DateTime{} = dt}, timezone),
    do: Timezone.local_date(dt, timezone)

  defp completed_on_date(_, _timezone), do: nil

  # The viewer's local calendar days for the trailing window, oldest-to-newest:
  # the last `window_days` days ending on the local "today".
  defp day_range(window_days, timezone) do
    today = Timezone.local_today(timezone)

    (-window_days + 1)..0
    |> Enum.map(&Date.add(today, &1))
  end

  # The UTC instant of the start of the local day `days_back` days before the
  # viewer's local "today" — the query boundary for a trailing local-day window.
  defp local_day_start(days_back, timezone) do
    timezone
    |> Timezone.local_today()
    |> Date.add(-days_back)
    |> Timezone.start_of_local_day(timezone)
  end

  defp empty_day_series(builder, window_days, timezone) when is_function(builder, 1) do
    window_days
    |> day_range(timezone)
    |> Enum.map(builder)
  end

  defp zero_flow_snapshot(date) do
    %{date: date, backlog: 0, ready: 0, doing: 0, review: 0, done: 0}
  end

  defp cfd_snapshot(tasks, date, timezone) do
    eod = Timezone.end_of_local_day(date, timezone)
    visible = Enum.reject(tasks, &archived_before?(&1, eod))
    counts = cfd_bucket_counts(visible, eod)

    Map.put(counts, :date, date)
  end

  defp cfd_bucket_counts(visible, eod) do
    %{
      backlog: Enum.count(visible, &backlog_at?(&1, eod)),
      ready: 0,
      doing: Enum.count(visible, &doing_at?(&1, eod)),
      review: Enum.count(visible, &review_at?(&1, eod)),
      done: Enum.count(visible, &done_at?(&1, eod))
    }
  end

  defp archived_before?(%{archived_at: %DateTime{} = a}, eod),
    do: DateTime.compare(a, eod) != :gt

  defp archived_before?(_, _), do: false

  defp inserted_before?(%{inserted_at: %NaiveDateTime{} = i}, eod) do
    i
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.compare(eod)
    |> Kernel.!=(:gt)
  end

  defp inserted_before?(_, _), do: false

  defp backlog_at?(task, eod) do
    inserted_before?(task, eod) and is_nil(task.claimed_at)
  end

  defp doing_at?(task, eod) do
    claimed_at_or_before?(task, eod) and not completed_at_or_before?(task, eod)
  end

  defp review_at?(task, eod) do
    task.needs_review and completed_at_or_before?(task, eod) and
      not reviewed_at_or_before?(task, eod)
  end

  defp done_at?(task, eod) do
    reviewed_at_or_before?(task, eod) or
      (completed_at_or_before?(task, eod) and not task.needs_review)
  end

  defp claimed_at_or_before?(%{claimed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp claimed_at_or_before?(_, _), do: false

  defp completed_at_or_before?(%{completed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp completed_at_or_before?(_, _), do: false

  defp reviewed_at_or_before?(%{reviewed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp reviewed_at_or_before?(_, _), do: false
end
