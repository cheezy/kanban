defmodule Kanban.Archives do
  @moduledoc """
  Read-only context for the workspace Archive view.

  A task is "archived" when its `:archived_at` field is set. The
  `:archive_reason` field categorizes why. A task archived without a reason
  (archiving from the board, single or in bulk, and legacy rows) counts as
  `:completed` only when it actually completed — `completed_at` is set or its
  status is `:completed`; otherwise its effective reason is `:none`. See
  `effective_reason/1`, which the stats, filters, rows and CSV export share.

  All public functions are scope-aware: when a `Kanban.Accounts.Scope`
  is passed, results are filtered to tasks on boards the scoped user can
  access via `Kanban.Boards.BoardUser` membership. When `nil`, the full
  set is returned.

  This module is read-only by design — writes (archive, unarchive) live
  on `Kanban.Tasks.AgentWorkflow` and `Kanban.Tasks.Lifecycle`. Mirrors
  the structure of `Kanban.Agents` and `Kanban.Reviews`.
  """

  import Ecto.Query, warn: false

  alias Kanban.CSV
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Returns the list of archived tasks, newest first.

  `:column` and `:archived_by` are preloaded so callers can render the
  board chip and the "archived by" avatar without N+1 lookups.

  ## Options

    * `:reason` — one of `:completed`, `:duplicate`, `:wontdo`,
      `:deferred`, `:cancelled`. Filters the result to rows whose
      effective reason (`effective_reason/1`) matches. `nil` (the default)
      returns every reason.
    * `:scope` — a `Kanban.Accounts.Scope.t/0`. Limits results to tasks
      on boards the scoped user is a member of. When `nil`, all archived
      tasks are returned.
  """
  @spec list_archived(keyword()) :: [Task.t()]
  def list_archived(opts \\ []) do
    Task
    |> archived_query()
    |> apply_reason(Keyword.get(opts, :reason))
    |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
    |> order_by([t], desc: t.archived_at)
    |> preload([:column, :archived_by])
    |> Repo.all()
  end

  @doc """
  Board-scoped variant of `list_archived/1` used by `KanbanWeb.ArchiveLive`.

  Preloads everything `KanbanWeb.ArchiveRow` reads —
  `:column`, `:assigned_to`, `:archived_by`, `:duplicate_of`, `:parent`
  — so the LiveView never has to touch Ecto / `Repo.preload` directly.

  Results are ordered newest first.
  """
  @spec list_archived_for_board(integer()) :: [Task.t()]
  def list_archived_for_board(board_id) when is_integer(board_id) do
    Task
    |> archived_query()
    |> where([_t, column: c], c.board_id == ^board_id)
    |> order_by([t], desc: t.archived_at)
    |> preload([:column, :assigned_to, :archived_by, :duplicate_of, :parent])
    |> Repo.all()
  end

  @csv_headers ~w(Identifier Title Type Goal Assignee)a ++
                 ["Archive Reason", "Archived At", "Archived By"]

  @doc """
  Builds a CSV export (RFC-4180) of every archived task on the given board.

  Reuses `list_archived_for_board/1` so the rows carry the same preloads.
  The first line is a header row; one data row follows per archived task
  with the columns: Identifier, Title, Type, Goal (parent title),
  Assignee, Archive Reason, Archived At, Archived By.

  Every field is RFC-4180 quoted/escaped and neutralized against CSV
  formula injection (a leading `=`, `+`, `-`, `@`, tab, or CR is prefixed
  with a single quote so spreadsheet apps do not execute it) by the shared
  `Kanban.CSV` encoder.
  """
  @spec export_csv_for_board(integer()) :: binary()
  def export_csv_for_board(board_id) when is_integer(board_id) do
    board_id
    |> list_archived_for_board()
    |> build_csv()
  end

  @doc """
  Encodes a list of archived `Task` structs into an RFC-4180 CSV string.

  Split out from `export_csv_for_board/1` so the encoding (quoting and
  formula-injection neutralization) is unit-testable without the database.
  """
  @spec build_csv([Task.t()]) :: binary()
  def build_csv(rows) when is_list(rows) do
    header = Enum.map(@csv_headers, &to_string/1)

    [header | Enum.map(rows, &csv_row_fields/1)]
    |> CSV.encode()
    |> Kernel.<>("\r\n")
  end

  @doc """
  The reason an archived task is shown and counted under: its
  `archive_reason` when set; otherwise `:completed` when the task actually
  completed (`completed_at` set or status `:completed`), and `:none` when it
  never did — such as a card archived from Review.

  ## Examples

      iex> effective_reason(%Task{archive_reason: :wontdo})
      :wontdo

      iex> effective_reason(%Task{archive_reason: nil, status: :in_progress})
      :none

  """
  @spec effective_reason(map()) :: atom()
  def effective_reason(%{archive_reason: reason}) when not is_nil(reason), do: reason
  def effective_reason(%{completed_at: %DateTime{}}), do: :completed
  def effective_reason(%{status: :completed}), do: :completed
  def effective_reason(_task), do: :none

  @doc """
  Returns archive counters for the header band of the Archive view.

  Buckets:

    * `:total` — every archived task in the scope
    * `:completed` — tasks whose effective reason is `:completed`
      (`effective_reason/1`)

  ## Options

    * `:scope` — see `list_archived/1`.
  """
  @spec archive_stats(keyword()) :: %{
          total: non_neg_integer(),
          completed: non_neg_integer()
        }
  def archive_stats(opts \\ []) do
    rows =
      Task
      |> archived_query()
      |> BoardScope.apply_board_scope(Keyword.get(opts, :scope))
      |> select([t], %{
        archive_reason: t.archive_reason,
        completed_at: t.completed_at,
        status: t.status
      })
      |> Repo.all()

    build_stats(rows)
  end

  @doc """
  Board-scoped variant of `archive_stats/1`. Returns the same map shape
  as `archive_stats/1` but counts only tasks archived on the given
  board, so the strip totals stay consistent with the per-board row
  list returned by `list_archived_for_board/1`.
  """
  @spec archive_stats_for_board(integer()) :: %{
          total: non_neg_integer(),
          completed: non_neg_integer()
        }
  def archive_stats_for_board(board_id) when is_integer(board_id) do
    rows =
      Task
      |> archived_query()
      |> where([_t, column: c], c.board_id == ^board_id)
      |> select([t], %{
        archive_reason: t.archive_reason,
        completed_at: t.completed_at,
        status: t.status
      })
      |> Repo.all()

    build_stats(rows)
  end

  defp build_stats(rows) do
    %{
      total: length(rows),
      completed: count_completed(rows)
    }
  end

  # --- Query helpers --------------------------------------------------------

  defp archived_query(query) do
    from(t in query,
      join: c in assoc(t, :column),
      as: :column,
      where: not is_nil(t.archived_at)
    )
  end

  defp apply_reason(query, nil), do: query

  # Mirrors effective_reason/1: a reasonless row is :completed only when the
  # task completed.
  defp apply_reason(query, :completed) do
    where(
      query,
      [t],
      t.archive_reason == :completed or
        (is_nil(t.archive_reason) and (not is_nil(t.completed_at) or t.status == :completed))
    )
  end

  defp apply_reason(query, reason) when is_atom(reason) do
    where(query, [t], t.archive_reason == ^reason)
  end

  # --- archive_stats helpers ------------------------------------------------

  defp count_completed(rows), do: Enum.count(rows, &(effective_reason(&1) == :completed))

  # --- CSV export helpers ---------------------------------------------------

  defp csv_row_fields(task) do
    [
      task.identifier,
      task.title,
      to_string(task.type),
      csv_goal_title(task),
      csv_user_label(task.assigned_to),
      csv_reason(effective_reason(task)),
      csv_archived_at(task.archived_at),
      csv_user_label(task.archived_by)
    ]
  end

  defp csv_goal_title(%{parent: %{title: title}}) when is_binary(title), do: title
  defp csv_goal_title(_), do: ""

  # Mirrors KanbanWeb.ArchiveRow.user_name/1 (name -> email), but renders a
  # blank cell rather than "?" for an absent user in the export.
  defp csv_user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp csv_user_label(%{email: email}) when is_binary(email), do: email
  defp csv_user_label(_), do: ""

  # The same bucketing as the Archive view; a task archived without a reason
  # that never completed has a blank cell.
  defp csv_reason(:none), do: ""
  defp csv_reason(reason), do: to_string(reason)

  defp csv_archived_at(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp csv_archived_at(_), do: ""
end
