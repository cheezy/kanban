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
      counted on its own. The sum follows each board's current workspace, so
      files on a board that left its Organization stop counting there and
      count again once it moves back.
    * `check_limits/3` — both limits for one more file of a given size.
    * `lock_for_upload/2` — key-share locks the uploader, board and comment
      rows the insert will reference, then locks the task row, then takes a
      transaction-scoped advisory lock on the quota scope, always in that
      order, so two uploads cannot both pass the re-check inside the insert
      transaction and an upload never deadlocks with a deletion.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards.Board
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
    TaskAttachment
    |> join(:inner, [a], b in Board, on: b.id == a.board_id)
    |> join(:inner, [_a, b], w in assoc(b, :workspace))
    |> where([_a, _b, w], w.organization_id == ^organization_id)
    |> select([a], type(coalesce(sum(a.byte_size), 0), :integer))
    |> Repo.one()
  end

  def bytes_used({:board, board_id}) do
    TaskAttachment
    |> where([a], a.board_id == ^board_id)
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
  Inside a transaction: takes `FOR KEY SHARE` locks on the rows the new
  attachment will reference, then locks the task row `FOR UPDATE`, then takes
  the advisory lock of the task's quota scope, and returns
  `{:ok, quota_scope}`. Returns `{:error, :not_found}` when the task, its
  column, or any referenced row is gone.

  `refs` names the rows the insert references besides the task:
  `:uploaded_by_id`, `:board_id` and `:comment_id` (each optional; `nil` is
  skipped). They are key-share locked first, in that order (uploader, board,
  comment), which is the order a deletion reaches them: account deletion
  locks the user before deleting their boards, and a board deletion locks the
  board before its cascade reaches the task. Without these locks the insert
  would only take them through its foreign-key checks, after it holds the
  task row, so a board, account or comment deletion that started in between
  deadlocked with the upload (Postgres error 40P01). With them, a deletion
  either finishes first (and this returns `:not_found`) or waits for the
  upload to commit, then cascades to the new row, whose blob the trigger
  queues.

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
