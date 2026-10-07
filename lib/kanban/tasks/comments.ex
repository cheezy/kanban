defmodule Kanban.Tasks.Comments do
  @moduledoc """
  Task comments: persistence plus authorization, extracted from the task form
  LiveComponent so the web layer holds no Ecto queries (see `CODE-REVIEW.md`,
  "LiveView / context boundary") and so the board UI, the REST API and the MCP
  `stride_add_comment` tool share one policy (`Kanban.Tasks.CommentPolicy`).

  Every mutating function takes the caller's scope first and loads the
  comment's task and board itself, so a board id is never trusted from the
  caller. Each successful create, update and delete broadcasts
  `{Kanban.Tasks.Comments, :comment_changed, %{task_id: _, board_id: _}}` on
  `"board:<board_id>"`, after the write has committed.

  Errors are `{:error, :unauthorized}` when the policy refuses,
  `{:error, :not_found}` when the task or comment no longer exists, and
  `{:error, %Ecto.Changeset{}}` when the content is invalid.
  """

  import Ecto.Query, warn: false

  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.Tasks.CommentPolicy
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  @doc """
  Creates a comment on `task`, authored by the scope's user.

  `task_id` is taken from the task struct and `author_user_id` from the scope,
  both set on the server-held struct and never cast from `attrs` (D111), so a
  comment cannot be redirected to another task or attributed to another user —
  `content` is the only client-controlled field.

  Options:

    * `:author_agent_name` — the agent that wrote the comment, if any.
  """
  def create_comment(scope, task, attrs, opts \\ [])

  def create_comment(scope, %Task{id: task_id}, attrs, opts) when is_integer(task_id) do
    with {:ok, board_id} <- authorize_create(scope, task_id),
         {:ok, comment} <- insert_comment(scope, task_id, attrs, opts) do
      broadcast(task_id, board_id)
      {:ok, comment}
    end
  end

  # An unsaved task (id nil) has no board to authorize against.
  def create_comment(_scope, %Task{}, _attrs, _opts), do: {:error, :not_found}

  @doc """
  Updates a comment's content and stamps `edited_at`. Only the author, while
  still a board member, may edit; `inserted_at` is never changed.

  The comment is re-read by id, so the caller's struct is used for its id
  only and a stale or forged `task_id` or author on it has no effect.
  """
  def update_comment(scope, %TaskComment{id: id}, attrs) do
    with {:ok, current, board_id} <- fetch_authorized(id, &CommentPolicy.can_edit?(scope, &1, &2)),
         {:ok, updated} <- persist_update(current, attrs) do
      broadcast(updated.task_id, board_id)
      {:ok, updated}
    end
  end

  @doc """
  Deletes a comment. The author (while still a member) or the board owner may
  delete. An owner deleting someone else's comment emits a
  `:comment_deleted_by_owner` audit event, which never carries the body.
  """
  def delete_comment(scope, %TaskComment{id: id}) do
    with {:ok, current, board_id} <-
           fetch_authorized(id, &CommentPolicy.can_delete?(scope, &1, &2)),
         {:ok, deleted} <- persist_delete(current) do
      after_delete(scope, deleted, board_id)
    end
  end

  @doc """
  Gets a comment by id. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_comment!(id), do: Repo.get!(TaskComment, id)

  @doc """
  Lists `task`'s comments oldest first, each with its `:author` preloaded.

  Performs no authorization: the caller must already have established that
  the viewer may see `task`.
  """
  def list_comments(%Task{id: task_id}) do
    TaskComment
    |> where([c], c.task_id == ^task_id)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> preload(:author)
    |> Repo.all()
  end

  @doc """
  Lists `task`'s comments (oldest first, `:author` preloaded) together with
  what the scope may do: `can_comment` for the thread and `can_edit` /
  `can_delete` per comment.

  The board is derived from the task server-side and the caller's access is
  resolved once through `CommentPolicy.resolve/2`, so the cost is a fixed number
  of queries (at most four: the task's board, the viewer's access, the comments
  and their authors) however many comments the task has. The flags are a rendering hint
  only: create, update and delete re-authorize on every call.

  Performs no read authorization, exactly like `list_comments/1`: the caller
  must already have established that the viewer may see `task`. Returns
  `{:error, :not_found}` for an unsaved or deleted task.
  """
  def list_comment_thread(scope, %Task{id: task_id} = task) when is_integer(task_id) do
    with {:ok, board_id} <- board_id_for_task(task_id) do
      viewer = CommentPolicy.resolve(scope, board_id)

      entries =
        task
        |> list_comments()
        |> Enum.map(fn comment ->
          %{
            comment: comment,
            can_edit: CommentPolicy.allowed?(viewer, :edit, comment),
            can_delete: CommentPolicy.allowed?(viewer, :delete, comment)
          }
        end)

      {:ok, %{can_comment: CommentPolicy.allowed?(viewer, :comment), entries: entries}}
    end
  end

  def list_comment_thread(_scope, %Task{}), do: {:error, :not_found}

  defp insert_comment(%{user: %{id: user_id}}, task_id, attrs, opts) do
    %TaskComment{
      task_id: task_id,
      author_user_id: user_id,
      author_agent_name: Keyword.get(opts, :author_agent_name)
    }
    |> TaskComment.changeset(attrs)
    |> Repo.insert()
  end

  defp persist_update(current, attrs) do
    current
    |> TaskComment.changeset(attrs)
    |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update(stale_error_field: :id)
    |> map_stale()
  end

  defp after_delete(scope, deleted, board_id) do
    maybe_audit_owner_delete(scope, deleted, board_id)
    broadcast(deleted.task_id, board_id)
    {:ok, deleted}
  end

  defp persist_delete(current) do
    current
    |> Repo.delete(stale_error_field: :id)
    |> map_stale()
  end

  defp authorize_create(scope, task_id) do
    with {:ok, board_id} <- board_id_for_task(task_id),
         :ok <- authorize(CommentPolicy.can_comment?(scope, board_id)) do
      {:ok, board_id}
    end
  end

  # Loads the comment with its task's board and applies `allowed?`, a
  # CommentPolicy predicate closed over the caller's scope, to the fresh row.
  defp fetch_authorized(comment_id, allowed?) do
    with {:ok, current, board_id} <- fetch_with_board(comment_id),
         :ok <- authorize(allowed?.(board_id, current)) do
      {:ok, current, board_id}
    end
  end

  defp board_id_for_task(task_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t], t.id == ^task_id)
    |> select([_t, c], c.board_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      board_id -> {:ok, board_id}
    end
  end

  defp fetch_with_board(comment_id) when not is_integer(comment_id), do: {:error, :not_found}

  defp fetch_with_board(comment_id) do
    TaskComment
    |> join(:inner, [c], t in assoc(c, :task))
    |> join(:inner, [_c, t], col in assoc(t, :column))
    |> where([c], c.id == ^comment_id)
    |> select([c, _t, col], {c, col.board_id})
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      {comment, board_id} -> {:ok, comment, board_id}
    end
  end

  defp authorize(true), do: :ok
  defp authorize(false), do: {:error, :unauthorized}

  # A comment deleted between our read and our write surfaces as a stale-entry
  # error on :id (rather than raising Ecto.StaleEntryError); report it as gone.
  defp map_stale({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :id), do: {:error, :not_found}, else: {:error, changeset}
  end

  defp map_stale(result), do: result

  defp maybe_audit_owner_delete(%{user: %{id: user_id}}, %TaskComment{} = deleted, board_id)
       when deleted.author_user_id != user_id do
    metadata =
      [
        user_id: user_id,
        board_id: board_id,
        task_id: deleted.task_id,
        comment_id: deleted.id,
        author_user_id: deleted.author_user_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    AuditLog.event(:comment_deleted_by_owner, metadata)
  end

  defp maybe_audit_owner_delete(_scope, _deleted, _board_id), do: :ok

  defp broadcast(task_id, board_id) do
    payload = %{task_id: task_id, board_id: board_id}

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, :comment_changed, payload}
    )

    :telemetry.execute(
      [:kanban, :pubsub, :broadcast],
      %{count: 1},
      Map.put(payload, :event, :comment_changed)
    )
  end
end
