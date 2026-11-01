defmodule Kanban.Attachments do
  @moduledoc """
  Files attached to tasks and comments: the single entry point for the board
  UI, the REST API and MCP. Nothing outside this context touches
  `Kanban.Attachments.TaskAttachment`, `Kanban.Attachments.Storage` or the
  Repo for attachments.

  ## Order of checks

  Every public function runs the same steps, in this order:

    1. Find the board through the task's column, never from the caller.
    2. Resolve the caller's access once (`Kanban.Attachments.Policy`). A
       non-member gets `{:error, :not_found}`, so attachment ids reveal
       nothing.
    3. `Kanban.Plans.check_board(board_id, :attachments, surface: :context)`.
       While plans are enforced a free board gets
       `{:error, {:plan_required, :attachments}}` from every function, which
       stores, lists or removes nothing. Its files stay in storage, hidden,
       and reappear if the board moves back into an Organization.
    4. Check the right. A member without it gets `{:error, :unauthorized}`.
    5. Only then look up the attachment or apply the limits.

  ## Rights

  Uploading needs owner or modify access; a comment-level upload also needs
  the comment to be on the same task and written by the uploader. Every
  member, `:read_only` included, may list and download. The uploader (while
  still a member) or the board owner may delete.

  ## Side effects

  A successful create or delete broadcasts
  `{Kanban.Attachments, :attachment_changed, %{task_id: _, board_id: _}}` on
  `"board:<board_id>"`. `delete_attachment/2` only deletes the row: the
  `AFTER DELETE` trigger queues the blob (`Kanban.Attachments.BlobDeletion`),
  so a rolled-back delete never loses a blob a row still points at. An owner
  deleting someone else's attachment emits the
  `:attachment_deleted_by_owner` audit event with ids only. Telemetry is
  `[:kanban, :attachment, :uploaded | :upload_refused | :downloaded |
  :deleted]`; see `docs/telemetry.md`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Attachments.Pipeline
  alias Kanban.Attachments.Policy
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.AuditLog
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  @type upload :: %{path: Path.t(), filename: String.t(), content_type: String.t() | nil}

  @type refusal ::
          :too_large
          | :type_not_allowed
          | :type_mismatch
          | :empty
          | :too_many_files
          | :quota_exceeded
          | :storage_unavailable

  @type error ::
          :not_found
          | :unauthorized
          | :unreadable
          | {:plan_required, :attachments}
          | refusal()
          | Ecto.Changeset.t()

  @doc """
  Attaches the uploaded file to `task`, or to one of its comments.

  `upload` is `%{path: temp_path, filename: name, content_type: type}`. The
  file's size comes from `File.stat` and its sha256 from reading it, never
  from the client. `task_id`, `board_id`, `uploaded_by_id` and the storage
  key are set by the server.

  Options:

    * `:comment` — a `Kanban.Tasks.TaskComment` on the same task, written by
      the caller, to attach the file to. A comment that is gone or on another
      task is `:not_found`; someone else's comment is `:unauthorized`.

  Errors are `{:error, reason}` with `reason` one of `:not_found`,
  `:unauthorized`, `{:plan_required, :attachments}`, `:unreadable` (the temp
  file is missing or unreadable), a refusal (`:too_large`,
  `:type_not_allowed`, `:type_mismatch`, `:empty`, `:too_many_files`,
  `:quota_exceeded`, `:storage_unavailable`), or a changeset for any other
  invalid field, such as an unusable file name. A refused or failed upload
  leaves no row.
  """
  @spec create_attachment(term(), Task.t(), upload(), keyword()) ::
          {:ok, TaskAttachment.t()} | {:error, error()}
  def create_attachment(scope, task, upload, opts \\ [])

  def create_attachment(scope, %Task{id: task_id}, upload, opts) when is_integer(task_id) do
    with {:ok, base} <- authorize_upload(scope, task_id, Keyword.get(opts, :comment)),
         {:ok, attachment} <- Pipeline.create(base, upload, source: :upload) do
      broadcast(task_id, base.board_id)
      {:ok, attachment}
    end
  end

  def create_attachment(_scope, _task, _upload, _opts), do: {:error, :not_found}

  @doc """
  Lists every attachment on `task`, task-level and comment-level together,
  oldest first. Each carries its `comment_id` (`nil` for a task-level file).
  """
  @spec list_task_attachments(term(), Task.t()) :: {:ok, [TaskAttachment.t()]} | {:error, error()}
  def list_task_attachments(scope, %Task{id: task_id}) when is_integer(task_id) do
    with {:ok, board_id} <- board_id_for_task(task_id),
         {:ok, _viewer} <- gate(scope, board_id, :read) do
      {:ok, TaskAttachment |> where([a], a.task_id == ^task_id) |> oldest_first() |> Repo.all()}
    end
  end

  def list_task_attachments(_scope, _task), do: {:error, :not_found}

  @doc "Lists the attachments on `comment` only, oldest first."
  @spec list_comment_attachments(term(), TaskComment.t()) ::
          {:ok, [TaskAttachment.t()]} | {:error, error()}
  def list_comment_attachments(scope, %TaskComment{id: comment_id}) when is_integer(comment_id) do
    with {:ok, board_id} <- board_id_for_comment(comment_id),
         {:ok, _viewer} <- gate(scope, board_id, :read) do
      {:ok,
       TaskAttachment |> where([a], a.comment_id == ^comment_id) |> oldest_first() |> Repo.all()}
    end
  end

  def list_comment_attachments(_scope, _comment), do: {:error, :not_found}

  @doc """
  Authorizes a download of the attachment with `attachment_id` and returns
  it. Any board member, `:read_only` included, may download; a non-member or
  an unknown or non-integer id gets `:not_found`. Emits
  `[:kanban, :attachment, :downloaded]` once the download is authorized.
  """
  @spec fetch_for_download(term(), term()) :: {:ok, TaskAttachment.t()} | {:error, error()}
  def fetch_for_download(scope, attachment_id) when is_integer(attachment_id) do
    with {:ok, board_id} <- board_id_for_attachment(attachment_id),
         {:ok, viewer} <- gate(scope, board_id, :read),
         {:ok, attachment} <- fetch(attachment_id) do
      emit_downloaded(attachment, board_id, viewer)
      {:ok, attachment}
    end
  end

  def fetch_for_download(_scope, _attachment_id), do: {:error, :not_found}

  @doc """
  Deletes `attachment`. The uploader (while still a member) or the board
  owner may delete; another member gets `:unauthorized`. The row is re-read,
  so the caller's struct is used for its id only.

  Only the row is deleted here: the database trigger queues the blob for the
  cleanup worker.
  """
  @spec delete_attachment(term(), TaskAttachment.t()) ::
          {:ok, TaskAttachment.t()} | {:error, error()}
  def delete_attachment(scope, %TaskAttachment{id: id}) when is_integer(id) do
    with {:ok, current, board_id, viewer} <- authorize_delete(scope, id),
         {:ok, deleted} <- current |> Repo.delete(stale_error_field: :id) |> map_stale() do
      after_delete(viewer, deleted, board_id)
    end
  end

  def delete_attachment(_scope, _attachment), do: {:error, :not_found}

  # ── Checks ─────────────────────────────────────────────────────────

  # Steps 2 to 4 of the moduledoc: membership, the plan, then the right.
  defp gate(scope, board_id, right) do
    viewer = Policy.resolve(scope, board_id)

    with :ok <- membership(viewer),
         :ok <- Plans.check_board(board_id, :attachments, surface: :context),
         :ok <- authorize(Policy.allowed?(viewer, right)) do
      {:ok, viewer}
    end
  end

  # Resolves and checks everything an upload needs, and returns the base
  # struct with the server-set ids.
  defp authorize_upload(scope, task_id, comment) do
    with {:ok, board_id} <- board_id_for_task(task_id),
         {:ok, viewer} <- gate(scope, board_id, :upload),
         {:ok, comment_id} <- comment_for_upload(viewer, task_id, comment) do
      {:ok,
       %TaskAttachment{
         task_id: task_id,
         board_id: board_id,
         comment_id: comment_id,
         uploaded_by_id: viewer.user_id
       }}
    end
  end

  # The row is re-read after the gate, so the caller's struct is used for its
  # id only.
  defp authorize_delete(scope, attachment_id) do
    with {:ok, board_id} <- board_id_for_attachment(attachment_id),
         {:ok, viewer} <- gate(scope, board_id, :read),
         {:ok, current} <- fetch(attachment_id),
         :ok <- authorize(Policy.allowed?(viewer, :delete, current)) do
      {:ok, current, board_id, viewer}
    end
  end

  defp membership(viewer), do: if(Policy.member?(viewer), do: :ok, else: {:error, :not_found})

  defp authorize(true), do: :ok
  defp authorize(false), do: {:error, :unauthorized}

  defp comment_for_upload(_viewer, _task_id, nil), do: {:ok, nil}

  defp comment_for_upload(viewer, task_id, %TaskComment{id: comment_id})
       when is_integer(comment_id) do
    case Repo.get(TaskComment, comment_id) do
      %TaskComment{task_id: ^task_id} = comment ->
        with :ok <- authorize(Policy.allowed?(viewer, :upload_to_comment, comment)),
             do: {:ok, comment.id}

      _missing_or_elsewhere ->
        {:error, :not_found}
    end
  end

  defp comment_for_upload(_viewer, _task_id, _comment), do: {:error, :not_found}

  # ── Lookups ────────────────────────────────────────────────────────

  defp board_id_for_task(task_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t], t.id == ^task_id)
    |> select([_t, c], c.board_id)
    |> Repo.one()
    |> found()
  end

  defp board_id_for_comment(comment_id) do
    TaskComment
    |> join(:inner, [c], t in assoc(c, :task))
    |> join(:inner, [_c, t], col in assoc(t, :column))
    |> where([c], c.id == ^comment_id)
    |> select([_c, _t, col], col.board_id)
    |> Repo.one()
    |> found()
  end

  # The board comes from the attachment's task's column, not from the row's
  # own board_id, so it is always the board the task lives on now.
  defp board_id_for_attachment(attachment_id) do
    TaskAttachment
    |> join(:inner, [a], t in assoc(a, :task))
    |> join(:inner, [_a, t], col in assoc(t, :column))
    |> where([a], a.id == ^attachment_id)
    |> select([_a, _t, col], col.board_id)
    |> Repo.one()
    |> found()
  end

  defp fetch(attachment_id), do: TaskAttachment |> Repo.get(attachment_id) |> found()

  defp found(nil), do: {:error, :not_found}
  defp found(value), do: {:ok, value}

  defp oldest_first(query), do: order_by(query, [a], asc: a.inserted_at, asc: a.id)

  # An attachment deleted between our read and our write surfaces as a
  # stale-entry error on :id; report it as gone.
  defp map_stale({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :id), do: {:error, :not_found}, else: {:error, changeset}
  end

  defp map_stale(result), do: result

  # ── Side effects ───────────────────────────────────────────────────

  defp after_delete(viewer, deleted, board_id) do
    maybe_audit_owner_delete(viewer, deleted, board_id)
    broadcast(deleted.task_id, board_id)
    emit_deleted(deleted, board_id, viewer)
    {:ok, deleted}
  end

  defp maybe_audit_owner_delete(%{user_id: user_id}, %TaskAttachment{} = deleted, board_id)
       when is_integer(user_id) and deleted.uploaded_by_id != user_id do
    metadata =
      [
        user_id: user_id,
        board_id: board_id,
        task_id: deleted.task_id,
        comment_id: deleted.comment_id,
        attachment_id: deleted.id,
        uploaded_by_id: deleted.uploaded_by_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    AuditLog.event(:attachment_deleted_by_owner, metadata)
  end

  defp maybe_audit_owner_delete(_viewer, _deleted, _board_id), do: :ok

  defp broadcast(task_id, board_id) do
    payload = %{task_id: task_id, board_id: board_id}

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, :attachment_changed, payload}
    )

    Kanban.Telemetry.emit(
      [:kanban, :pubsub, :broadcast],
      %{count: 1},
      Map.put(payload, :event, :attachment_changed)
    )
  end

  defp emit_downloaded(attachment, board_id, viewer) do
    Kanban.Telemetry.emit(
      [:kanban, :attachment, :downloaded],
      %{count: 1, byte_size: attachment.byte_size},
      %{
        attachment_id: attachment.id,
        task_id: attachment.task_id,
        board_id: board_id,
        user_id: viewer.user_id
      }
    )
  end

  defp emit_deleted(attachment, board_id, viewer) do
    Kanban.Telemetry.emit(
      [:kanban, :attachment, :deleted],
      %{count: 1, byte_size: attachment.byte_size},
      %{
        attachment_id: attachment.id,
        task_id: attachment.task_id,
        board_id: board_id,
        user_id: viewer.user_id
      }
    )
  end
end
