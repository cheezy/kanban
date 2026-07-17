defmodule Kanban.Metrics.Workspace do
  @moduledoc """
  Workspace-level (cross-board) metric reads that back the `/metrics` page.

  Extracted from `Kanban.Metrics` (W1439) to keep that context under the
  module-size guideline. These functions aggregate across every board the
  scoped user can access, rather than operating on a single board id like the
  board-level reads in `Kanban.Metrics`.

  This module is the public façade. It resolves the visible board id set and
  the client options, then delegates the actual reads and derivations to focused
  sibling modules (extracted in W1737):

    * `Kanban.Metrics.Workspace.CompletedTasks` — the single projected
      completed-task query and its KPI/cycle-time/throughput/leaderboard
      derivations
    * `Kanban.Metrics.Workspace.CumulativeFlow` — the cumulative-flow query and
      per-day snapshot derivation
    * `Kanban.Metrics.Workspace.Windows` — the shared local-day window helpers
      both sibling modules use

  Five workspace-scoped functions back the `/metrics` page and aggregate
  across every board the scoped user can access:

    * `workspace_kpis/1` — KPI strip with delta-vs-previous-14-day percentages
    * `cycle_time_daily/1` — 14 daily median cycle times
    * `throughput_daily/1` — 14 daily completion counts
    * `agent_leaderboard/1` — top 6 contributors (agents before humans)
    * `cumulative_flow/1` — 14 daily snapshots across 5 derived states

  `overview/1` returns all five payloads in one call, deriving the four
  completed-task-based series from a single projected fetch (the fifth,
  `flow_snapshots`, keeps `cumulative_flow/1`'s own read). The LiveView
  uses it so a render issues one completed-task query instead of five.

  All five accept `opts` with `:scope` and route through
  `Kanban.Boards.list_boards(scope.user)` to derive the visible board id
  set. A `nil` scope or a scope with `nil` user returns the empty/zero
  shape — never raises.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Metrics.Workspace.CompletedTasks
  alias Kanban.Metrics.Workspace.CumulativeFlow

  @workspace_window_days 14
  @allowed_window_days [7, 14, 30, 90]

  @doc """
  Returns every `/metrics` page payload in one call: `:kpis`,
  `:cycle_series`, `:throughput_series`, `:leaderboard`, and
  `:flow_snapshots`. The four completed-task-based payloads are derived
  from a single projected fetch spanning both the current and previous
  KPI windows, partitioned in memory — collapsing the five separate
  fetches the individual reads would otherwise issue. `:flow_snapshots`
  keeps `cumulative_flow/1`'s own read (a sibling task narrows it).

  Each value is identical to the matching individual public function
  called with the same `opts`. Accepts the same `:scope`,
  `:window_days`, `:board_ids`, and `:timezone` options; a `nil` scope
  or a scope with a `nil` user returns the zero shape without querying.
  `Kanban.Boards.list_boards/1` is invoked at most once per call.
  """
  @spec overview(keyword()) :: %{
          kpis: map(),
          cycle_series: [%{date: Date.t(), minutes: non_neg_integer()}],
          throughput_series: [non_neg_integer()],
          leaderboard: [map()],
          flow_snapshots: [map()]
        }
  def overview(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    case scoped_board_ids(opts) do
      [] -> zero_overview(window_days, timezone)
      board_ids -> build_overview(board_ids, window_days, timezone)
    end
  end

  @doc """
  Returns the same map shape as `overview/1` filled with the zero/empty
  payloads, WITHOUT running any query. The disconnected LiveView mount seeds
  this so the static first render is instant and every assign the template
  reads is present; the connected mount then replaces it with `overview/1`.

  Only `:window_days` and `:timezone` are read (to size the empty day series);
  `:scope` and `:board_ids` are ignored because nothing is fetched.
  """
  @spec placeholder_overview(keyword()) :: %{
          kpis: map(),
          cycle_series: [map()],
          throughput_series: [non_neg_integer()],
          leaderboard: [map()],
          flow_snapshots: [map()]
        }
  def placeholder_overview(opts \\ []) do
    window_days = resolve_window_days(opts)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    zero_overview(window_days, timezone)
  end

  defp zero_overview(window_days, timezone) do
    %{
      kpis: CompletedTasks.zero_kpis(),
      cycle_series: CompletedTasks.empty_cycle_series(window_days, timezone),
      throughput_series: CompletedTasks.empty_throughput_series(window_days),
      leaderboard: [],
      flow_snapshots: CumulativeFlow.empty_snapshots(window_days, timezone)
    }
  end

  # One fetch covering both KPI windows, partitioned in memory and reshaped into
  # the four completed-task payloads (`CompletedTasks.overview_series/3`), merged
  # with `flow_snapshots` from `cumulative_flow`'s own broader read. `board_ids`
  # is resolved once by the caller and threaded through, so `Boards.list_boards`
  # runs at most once per overview.
  defp build_overview(board_ids, window_days, timezone) do
    board_ids
    |> CompletedTasks.overview_series(window_days, timezone)
    |> Map.put(:flow_snapshots, CumulativeFlow.snapshots(board_ids, window_days, timezone))
  end

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
        CompletedTasks.zero_kpis()

      board_ids ->
        window_days = resolve_window_days(opts)
        timezone = Keyword.get(opts, :timezone, "Etc/UTC")
        CompletedTasks.kpis(board_ids, window_days, timezone)
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
      [] -> CompletedTasks.empty_cycle_series(window_days, timezone)
      board_ids -> CompletedTasks.cycle_time_daily(board_ids, window_days, timezone)
    end
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
      [] -> CompletedTasks.empty_throughput_series(window_days)
      board_ids -> CompletedTasks.throughput_daily(board_ids, window_days, timezone)
    end
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
      board_ids -> CompletedTasks.leaderboard(board_ids, window_days, timezone)
    end
  end

  @doc """
  Returns daily cumulative-flow snapshots, oldest-to-newest. Each
  snapshot has integer counts for `:backlog`, `:ready`, `:doing`,
  `:review`, and `:done`. See `Kanban.Metrics.Workspace.CumulativeFlow`
  for the per-state approximation rules. The series length is the
  resolved `:window_days` option (default #{@workspace_window_days}).
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
      [] -> CumulativeFlow.empty_snapshots(window_days, timezone)
      board_ids -> CumulativeFlow.snapshots(board_ids, window_days, timezone)
    end
  end

  # --- Scope & option resolution -------------------------------------------

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
end
