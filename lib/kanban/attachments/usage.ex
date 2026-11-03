defmodule Kanban.Attachments.Usage do
  @moduledoc """
  How much a task and an Organization already hold, and the locks that keep
  those numbers honest under concurrent uploads.

    * `count_for_task/1` — attachments on one task, for
      `Kanban.Attachments.Limits.max_files_per_task/0`.
    * `quota_scope/1` and `bytes_used/1` — the bytes counted against
      `Kanban.Attachments.Limits.organization_quota_bytes/0`. A board in an
      Organization counts every file on every board of that Organization; a
      board outside one (possible only while plans are not enforced) is
      counted on its own. The sum follows each file's task to its column's
      board and that board's current workspace, so files on a board that left
      its Organization stop counting there and count again once it moves
      back, and a file always counts where its task is.
    * `check_limits/3` — both limits for one more file of a given size.
    * `lock_for_upload/2` — key-share locks the uploader, the task's board
      and the comment rows, then locks the task row, then takes a
      transaction-scoped advisory lock on the quota scope, always in that
      order, so two uploads cannot both pass the re-check inside the insert
      transaction and an upload never deadlocks with a deletion.
    * `check_board_move/2` — whether a board's files fit in what an
      Organization has left, under the same advisory lock, for
      `Kanban.Workspaces.BoardMoves`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  # The two-key advisory lock form (int4, int4) lives in a different key
  # space from the single-key bigint locks taken on column and board ids
  # elsewhere, so these can never collide with them. Each scope gets its own
  # namespace so an Organization id and a board id never share a lock.
  @organization_lock_namespace 41_001
  @board_lock_namespace 41_002
  @int4_range 2_147_483_648

  @typedoc "What the quota counts against."
  @type quota_scope :: {:organization, integer()} | {:board, integer()}

  @doc "The number of attachments on the task with id `task_id`."
  @spec count_for_task(integer()) :: non_neg_integer()
  def count_for_task(task_id) do
    TaskAttachment
    |> where([a], a.task_id == ^task_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  The quota scope of the board with id `board_id`: `{:organization, id}` when
  its workspace belongs to an Organization, else `{:board, board_id}`.
  """
  @spec quota_scope(integer()) :: quota_scope()
  def quota_scope(board_id) do
    Board
    |> join(:left, [b], w in assoc(b, :workspace))
    |> where([b], b.id == ^board_id)
    |> select([_b, w], w.organization_id)
    |> Repo.one()
    |> case do
      organization_id when is_integer(organization_id) -> {:organization, organization_id}
      nil -> {:board, board_id}
    end
  end

  @doc "The total `byte_size` of every attachment in the quota scope, as an integer."
  @spec bytes_used(quota_scope()) :: non_neg_integer()
  def bytes_used({:organization, organization_id}) do
    with_board()
    |> join(:inner, [_a, _t, c], b in Board, on: b.id == c.board_id)
    |> join(:inner, [_a, _t, _c, b], w in assoc(b, :workspace))
    |> where([_a, _t, _c, _b, w], w.organization_id == ^organization_id)
    |> sum_bytes()
  end

  def bytes_used({:board, board_id}) do
    with_board()
    |> where([_a, _t, c], c.board_id == ^board_id)
    |> sum_bytes()
  end

  # An attachment's board is its task's column's board; a row stores none.
  defp with_board do
    TaskAttachment
    |> join(:inner, [a], t in Task, on: t.id == a.task_id)
    |> join(:inner, [_a, t], c in Column, on: c.id == t.column_id)
  end

  defp sum_bytes(query) do
    query
    |> select([a], type(coalesce(sum(a.byte_size), 0), :integer))
    |> Repo.one()
  end

  @doc """
  `:ok` when the task can take one more file of `byte_size` bytes. Returns
  `{:error, :too_many_files}` when it already holds
  `Limits.max_files_per_task/0`, or `{:error, :quota_exceeded}` when the file
  would take the scope past `Limits.organization_quota_bytes/0`.
  """
  @spec check_limits(integer(), quota_scope(), non_neg_integer()) ::
          :ok | {:error, :too_many_files | :quota_exceeded}
  def check_limits(task_id, scope, byte_size) do
    cond do
      count_for_task(task_id) >= Limits.max_files_per_task() ->
        {:error, :too_many_files}

      bytes_used(scope) + byte_size > Limits.organization_quota_bytes() ->
        {:error, :quota_exceeded}

      true ->
        :ok
    end
  end

  @doc """
  Inside a transaction: takes `FOR KEY SHARE` locks on the rows the upload
  depends on, then locks the task row `FOR UPDATE`, then takes
  the advisory lock of the task's quota scope, and returns
  `{:ok, quota_scope}`. Returns `{:error, :not_found}` when the task, its
  column, or any referenced row is gone.

  `refs` names the rows the upload depends on besides the task:
  `:uploaded_by_id`, `:board_id` (the task's board, which the row does not
  store) and `:comment_id` (each optional; `nil` is skipped). They are
  key-share locked first, in that order (uploader, board, comment), which is
  the order a deletion reaches them: account deletion
  locks the user before deleting their boards, and a board deletion locks the
  board before its cascade reaches the task. Without these locks the insert
  would take the uploader and comment locks only through its foreign-key
  checks, after it holds the task row, so an account or comment deletion
  that started in between deadlocked with the upload (Postgres error 40P01),
  as a board deletion did while the row still referenced its board. With
  them, a deletion either finishes first (and this returns `:not_found`) or
  waits for the upload to commit, then cascades to the new row, whose blob
  the trigger queues. The board row, which the row no longer references,
  would otherwise not be locked at all: its key-share lock is also what
  makes a board move into an Organization (`check_board_move/2`) wait for
  an upload to that board, or the upload wait for the move.

  The task row lock serializes uploads to one task, so the count re-check
  holds; the advisory lock serializes uploads across the scope, so the quota
  re-check holds. A key taken modulo 2^31 can make two scopes share a lock,
  which only serializes them more than needed.
  """
  @spec lock_for_upload(integer(), keyword()) :: {:ok, quota_scope()} | {:error, :not_found}
  def lock_for_upload(task_id, refs \\ []) do
    with :ok <- key_share(User, refs[:uploaded_by_id]),
         :ok <- key_share(Board, refs[:board_id]),
         :ok <- key_share(TaskComment, refs[:comment_id]),
         {:ok, board_id} <- lock_task(task_id) do
      scope = quota_scope(board_id)
      advisory_lock(scope)
      {:ok, scope}
    end
  end

  @doc """
  Inside a board move's transaction: takes the advisory lock of the
  Organization with id `organization_id`, the lock an upload into it takes,
  then checks that the files on the board with id `board_id` fit in what the
  Organization has left. While the move holds the lock, no upload into the
  Organization can pass its quota re-check, so the two cannot both use the
  last of the quota.

  Returns `:ok`, or `{:error, {:quota_exceeded, sizes}}` where `sizes` holds
  `:board_bytes` (the board's files), `:available_bytes` (what the
  Organization has left, 0 when it is already at or over its quota) and
  `:shortfall_bytes` (how much more room the move needs). A board without
  files always fits, even into an Organization at or over its quota, so a
  move that brings no files is never refused for storage.

  The board must not be in the Organization yet: its files are counted on
  their own and added to the Organization's.
  """
  @spec check_board_move(integer(), integer()) ::
          :ok
          | {:error,
             {:quota_exceeded,
              %{
                board_bytes: pos_integer(),
                available_bytes: non_neg_integer(),
                shortfall_bytes: pos_integer()
              }}}
  def check_board_move(board_id, organization_id) do
    advisory_lock({:organization, organization_id})

    board_bytes = bytes_used({:board, board_id})
    used = bytes_used({:organization, organization_id})
    quota = Limits.organization_quota_bytes()

    if board_bytes == 0 or used + board_bytes <= quota do
      :ok
    else
      {:error,
       {:quota_exceeded,
        %{
          board_bytes: board_bytes,
          available_bytes: max(quota - used, 0),
          shortfall_bytes: used + board_bytes - quota
        }}}
    end
  end

  @doc """
  Inside a transaction: takes the advisory lock of `scope`, the lock an
  upload into that scope and a board move into an Organization take, so a
  caller that checks the quota and then writes files under it (a workspace
  import) cannot race them for the last of the quota.
  """
  @spec lock_quota(quota_scope()) :: :ok
  def lock_quota({kind, id} = scope) when kind in [:organization, :board] and is_integer(id),
    do: advisory_lock(scope)

  defp key_share(_schema, nil), do: :ok

  defp key_share(schema, id) when is_integer(id) do
    schema
    |> where([r], r.id == ^id)
    |> lock("FOR KEY SHARE")
    |> select([r], r.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  defp lock_task(task_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t], t.id == ^task_id)
    |> lock("FOR UPDATE OF t0")
    |> select([_t, c], c.board_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      board_id -> {:ok, board_id}
    end
  end

  defp advisory_lock({kind, id}) do
    namespace =
      if kind == :organization, do: @organization_lock_namespace, else: @board_lock_namespace

    Repo.query!("SELECT pg_advisory_xact_lock($1::int, $2::int)", [
      namespace,
      rem(id, @int4_range)
    ])

    :ok
  end
end
