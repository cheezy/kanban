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

  Mentions: on create and update the content's `@[Name](user:ID)` tokens
  (`Kanban.Tasks.Mentions`) are resolved against the comment's board,
  server-side, and only ids of current members — at most
  `Kanban.Tasks.Mentions.max_mentions/0` of them — are stored in
  `mentioned_user_ids`. The returned comment's virtual
  `newly_mentioned_user_ids` names the members that write newly mentions.
  After the write commits, `Kanban.Tasks.CommentNotifier` sends each of them
  except the author a `:mentioned` notification; a notification failure is
  logged and never changes the save's result.

  Errors are `{:error, :unauthorized}` when the policy refuses,
  `{:error, :not_found}` when the task or comment no longer exists, and
  `{:error, %Ecto.Changeset{}}` when the content is invalid.
  """

  import Ecto.Query, warn: false

  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.CommentNotifier
  alias Kanban.Tasks.CommentPolicy
  alias Kanban.Tasks.Mentions
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  @doc """
  Creates a comment on `task`, authored by the scope's user.

  `task_id` is taken from the task struct and `author_user_id` from the scope,
  both set on the server-held struct and never cast from `attrs` (D111), so a
  comment cannot be redirected to another task or attributed to another user —
  `content` is the only client-controlled field.

  `mentioned_user_ids` is resolved from the content against the task's board
  members, and the returned comment's `newly_mentioned_user_ids` equals it.

  Options:

    * `:author_agent_name` — the agent that wrote the comment, if any. Longer
      than 255 characters is a changeset error on `:author_agent_name`.
  """
  def create_comment(scope, task, attrs, opts \\ [])

  def create_comment(scope, %Task{id: task_id}, attrs, opts) when is_integer(task_id) do
    with {:ok, board_id} <- authorize_create(scope, task_id),
         {:ok, comment} <- insert_comment(scope, task_id, board_id, attrs, opts) do
      after_write(scope, comment, [], board_id)
    end
  end

  # An unsaved task (id nil) has no board to authorize against.
  def create_comment(_scope, %Task{}, _attrs, _opts), do: {:error, :not_found}

  @doc """
  Updates a comment's content and stamps `edited_at`. Only the author, while
  still a board member, may edit; `inserted_at` is never changed.

  The comment is re-read by id, so the caller's struct is used for its id
  only and a stale or forged `task_id` or author on it has no effect.

  `mentioned_user_ids` is recomputed from the new content against the board's
  current members, so removed mentions drop out. The returned comment's
  `newly_mentioned_user_ids` holds only the ids the edit added.
  """
  def update_comment(scope, %TaskComment{id: id}, attrs) do
    with {:ok, current, board_id} <- fetch_authorized(id, &CommentPolicy.can_edit?(scope, &1, &2)),
         {:ok, updated} <- persist_update(current, attrs, board_id) do
      after_write(scope, updated, current.mentioned_user_ids, board_id)
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
  Lists the `limit` most recent of `task`'s comments, returned oldest first
  with `:author` preloaded, together with whether older comments were left
  out: `{comments, has_more}`.

  The most recent comments are the ones kept because a reader of a long
  thread needs the latest feedback. Ties on `inserted_at` are broken by id,
  so the cut is deterministic.

  Performs no authorization, exactly like `list_comments/1`.
  """
  def list_recent_comments(%Task{id: task_id}, limit)
      when is_integer(limit) and limit > 0 do
    rows =
      TaskComment
      |> where([c], c.task_id == ^task_id)
      |> order_by([c], desc: c.inserted_at, desc: c.id)
      |> limit(^(limit + 1))
      |> preload(:author)
      |> Repo.all()

    kept = rows |> Enum.take(limit) |> Enum.reverse()
    {kept, length(rows) > limit}
  end

  @doc """
  Lists `task`'s comments (oldest first, `:author` preloaded) together with
  what the scope may do: `can_comment` for the thread and `can_edit` /
  `can_delete` per comment.

  The board is derived from the task server-side and the caller's access is
  resolved once through `CommentPolicy.resolve/2`, so the cost is a fixed number
  of queries (at most five: the task's board, the viewer's access, the comments,
  their authors and the mentioned members) however many comments the task has.
  The flags are a rendering hint only: create, update and delete re-authorize
  on every call.

  Each entry also carries `mentions`, a map of user id to the display name to
  show (current name, else email) for the comment's stored mentions whose user
  is still a board member. A mention of anyone else is absent, so the renderer
  shows its token as plain text.

  Performs no read authorization, exactly like `list_comments/1`: the caller
  must already have established that the viewer may see `task`. Returns
  `{:error, :not_found}` for an unsaved or deleted task.
  """
  def list_comment_thread(scope, %Task{id: task_id} = task) when is_integer(task_id) do
    with {:ok, board_id} <- board_id_for_task(task_id) do
      viewer = CommentPolicy.resolve(scope, board_id)
      comments = list_comments(task)
      names = mention_names(board_id, comments)

      entries =
        Enum.map(comments, fn comment ->
          %{
            comment: comment,
            can_edit: CommentPolicy.allowed?(viewer, :edit, comment),
            can_delete: CommentPolicy.allowed?(viewer, :delete, comment),
            mentions: Map.take(names, comment.mentioned_user_ids)
          }
        end)

      {:ok, %{can_comment: CommentPolicy.allowed?(viewer, :comment), entries: entries}}
    end
  end

  def list_comment_thread(_scope, %Task{}), do: {:error, :not_found}

  @doc """
  Searches the members of `task`'s board for the comment `@mention`
  autocomplete, returning at most `limit` `%{id: id, label: label}` maps.

  The board is derived from the task server-side and the search is
  `Kanban.Boards.search_board_members/4`, so `query` matches a member's name
  or email and the scope's user must be a member of that board; otherwise —
  including a `nil` scope — the result is `{:error, :unauthorized}`.

  `label` is the member's name, else their email, passed through
  `Kanban.Tasks.Mentions.token_name/1`, so `@[label](user:id)` is always a
  valid mention token. Emails are not returned.

  Returns `{:error, :not_found}` for an unsaved or deleted task.
  """
  def search_mentionable_members(scope, %Task{id: task_id}, query, limit)
      when is_integer(task_id) and is_binary(query) and is_integer(limit) do
    with {:ok, board_id} <- board_id_for_task(task_id),
         {:ok, members} <-
           Boards.search_board_members(scope, %Board{id: board_id}, query, limit) do
      {:ok, Enum.flat_map(members, &mention_candidate/1)}
    end
  end

  def search_mentionable_members(_scope, %Task{}, _query, _limit), do: {:error, :not_found}

  defp mention_candidate(%{id: id} = member) do
    case member |> mention_label() |> Mentions.token_name() do
      "" -> fallback_candidate(member)
      label -> [%{id: id, label: label}]
    end
  end

  # A name that token_name/1 empties (only whitespace) falls back to the email.
  defp fallback_candidate(%{id: id, email: email}) when is_binary(email) do
    case Mentions.token_name(email) do
      "" -> []
      label -> [%{id: id, label: label}]
    end
  end

  defp fallback_candidate(_member), do: []

  defp insert_comment(%{user: %{id: user_id}}, task_id, board_id, attrs, opts) do
    %TaskComment{task_id: task_id, author_user_id: user_id}
    |> TaskComment.changeset(attrs)
    |> TaskComment.put_author_agent_name(Keyword.get(opts, :author_agent_name))
    |> put_mentions(board_id)
    |> Repo.insert()
    |> with_newly_mentioned([])
  end

  defp persist_update(current, attrs, board_id) do
    current
    |> TaskComment.changeset(attrs)
    |> put_mentions(board_id)
    |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update(stale_error_field: :id)
    |> map_stale()
    |> with_newly_mentioned(current.mentioned_user_ids)
  end

  # Only a valid changeset is worth a membership query; an invalid one is
  # never written. Disabled members are dropped here, so they are never stored
  # as mentioned and never notified.
  defp put_mentions(%Ecto.Changeset{valid?: true} = changeset, board_id) do
    ids = changeset |> Ecto.Changeset.get_field(:content) |> Mentions.parse()
    member_ids = board_id |> Boards.members_among(ids, active_only: true) |> Enum.map(& &1.id)

    Ecto.Changeset.put_change(changeset, :mentioned_user_ids, Mentions.resolve(ids, member_ids))
  end

  defp put_mentions(changeset, _board_id), do: changeset

  defp with_newly_mentioned({:ok, %TaskComment{} = comment}, previous_ids) do
    added = Mentions.added(previous_ids || [], comment.mentioned_user_ids)
    {:ok, %{comment | newly_mentioned_user_ids: added}}
  end

  defp with_newly_mentioned(error, _previous_ids), do: error

  # One query for every comment's mentions, keyed by id. Re-checking membership
  # here (not just at write time) means a member removed since the comment was
  # written stops rendering as a chip, and a rename shows the new name.
  defp mention_names(board_id, comments) do
    ids = comments |> Enum.flat_map(& &1.mentioned_user_ids) |> Enum.uniq()

    board_id
    |> Boards.members_among(ids)
    |> Map.new(fn member -> {member.id, mention_label(member)} end)
  end

  defp mention_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp mention_label(%{email: email}), do: email

  # Side effects of a committed create or update: the board broadcast, then the
  # mention notifications for the users this write newly mentions.
  defp after_write(scope, comment, previous_mentioned_ids, board_id) do
    broadcast(comment.task_id, board_id)
    CommentNotifier.notify_mentions(comment, previous_mentioned_ids, board_id, scope_user(scope))
    {:ok, comment}
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

  defp scope_user(%{user: user}), do: user
  defp scope_user(_scope), do: nil

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
