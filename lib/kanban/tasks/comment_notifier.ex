defmodule Kanban.Tasks.CommentNotifier do
  @moduledoc """
  Delivers `@mention` notifications for a comment that has just been saved.

  `Kanban.Tasks.Comments` calls `notify_mentions/4` after a create or update
  has committed (never inside the write), with the comment's previously
  stored `mentioned_user_ids` (`[]` on create). Only the users the write newly
  mentions are notified, the comment's author never is, and an edit that
  leaves the mentions unchanged notifies nobody.

  Notifications are emitted through `Kanban.Notifications.notify/3` with the
  `:mentioned` event type, which also re-checks board membership at send
  time, so a member removed between parse and notify is skipped.

  The payload references the task and the comment (`task_id`, a task
  `url_path` and a `comment_id` in `metadata`) and never copies the comment's
  content: a recipient who later loses board access keeps no copy of it, and
  `Kanban.Notifications` hides board-scoped rows once membership ends.

  The actor is the comment's `author_agent_name` when an agent wrote it
  (comments posted through the API or MCP), followed by the token user's name
  in parentheses because the client chooses the agent name — for example
  `"Claude (Ada Lovelace)"`. Otherwise it is the author's name. It is never
  their email, and it is trimmed to 255 characters.

  Dedupe keys are `mentioned:<comment id>:<version>`, where the version is
  `created` for a new comment and the `edited_at` second of an edit. A retry
  of the same write therefore notifies once, while a mention removed by one
  edit and restored by a later one notifies again, because the later edit
  newly mentions that user.

  `notify_mentions/4` never raises and always returns `:ok`. A failure is
  logged with the comment id and an error kind only, so it can never change
  the result of the comment save.
  """

  alias Kanban.Notifications
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  require Logger

  @event_type :mentioned
  @title_max 255
  @actor_max 255

  @doc """
  Returns the ids in `comment.mentioned_user_ids` that are not in
  `previous_ids`, in the comment's order, without the comment's author.

  ## Examples

      iex> Kanban.Tasks.CommentNotifier.new_mentions(
      ...>   [2],
      ...>   %Kanban.Tasks.TaskComment{author_user_id: 1, mentioned_user_ids: [1, 2, 3]}
      ...> )
      [3]
  """
  @spec new_mentions([integer()] | nil, TaskComment.t()) :: [integer()]
  def new_mentions(previous_ids, %TaskComment{} = comment) do
    previous = MapSet.new(previous_ids || [])

    Enum.reject(comment.mentioned_user_ids || [], fn id ->
      id == comment.author_user_id or MapSet.member?(previous, id)
    end)
  end

  @doc """
  Notifies the users `comment` newly mentions compared with `previous_ids`.

  `board_id` is the comment's board, resolved server-side by the caller, and
  `author` is the user who wrote the comment (the caller's scope user).
  Always returns `:ok`.
  """
  @spec notify_mentions(TaskComment.t(), [integer()] | nil, integer(), map() | nil) :: :ok
  def notify_mentions(%TaskComment{} = comment, previous_ids, board_id, author) do
    case new_mentions(previous_ids, comment) do
      [] -> :ok
      recipient_ids -> safely(comment, fn -> emit(comment, recipient_ids, board_id, author) end)
    end
  end

  @doc """
  Builds the `Kanban.Notifications.notify/3` attributes for a mention in
  `comment` on `task`, a task on board `board_id`.
  """
  @spec notification_attrs(TaskComment.t(), Task.t(), integer(), map() | nil) :: map()
  def notification_attrs(%TaskComment{} = comment, %Task{} = task, board_id, author) do
    %{
      title: title(task),
      url_path: "/boards/#{board_id}/tasks/#{task.id}/edit#comment-#{comment.id}",
      actor_name: actor_name(comment, author),
      metadata: %{"comment_id" => comment.id},
      board_id: board_id,
      task_id: task.id,
      dedupe_key: dedupe_key(comment)
    }
  end

  defp emit(comment, recipient_ids, board_id, author) do
    case Repo.get(Task, comment.task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        recipients = Enum.map(recipient_ids, &%{id: &1})
        attrs = notification_attrs(comment, task, board_id, author)
        Notifications.notify(@event_type, recipients, attrs)
    end
  end

  defp title(task) do
    [task.identifier, task.title]
    |> Enum.reject(&blank?/1)
    |> Enum.join(": ")
    |> String.slice(0, @title_max)
  end

  defp blank?(value), do: is_nil(value) or value == ""

  # The agent name is chosen by the API client, so the token's user is shown
  # beside it: "Claude (Ada Lovelace)". The agent part is trimmed to keep the
  # whole within the notification's 255-character actor limit. The author's
  # email is never used.
  defp actor_name(%TaskComment{author_agent_name: agent}, author)
       when is_binary(agent) and agent != "" do
    case author_name(author) do
      nil -> String.slice(agent, 0, @actor_max)
      name -> agent_with_user(agent, name)
    end
  end

  defp actor_name(_comment, author), do: author_name(author)

  defp author_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp author_name(_author), do: nil

  defp agent_with_user(agent, name) do
    suffix = " (" <> name <> ")"
    room = max(@actor_max - String.length(suffix), 1)
    String.slice(String.slice(agent, 0, room) <> suffix, 0, @actor_max)
  end

  defp dedupe_key(%TaskComment{id: id, edited_at: nil}), do: "mentioned:#{id}:created"

  defp dedupe_key(%TaskComment{id: id, edited_at: %DateTime{} = edited_at}),
    do: "mentioned:#{id}:#{DateTime.to_unix(edited_at)}"

  defp safely(comment, fun) do
    case fun.() do
      {:error, reason} -> log_failure(comment, describe(reason))
      _ok -> :ok
    end
  rescue
    exception -> log_failure(comment, inspect(exception.__struct__))
  end

  defp describe(%Ecto.Changeset{errors: errors}), do: errors |> Keyword.keys() |> inspect()
  defp describe(reason), do: inspect(reason)

  # Ids and an error kind only — never the comment content, the task title or
  # an exception message, which can carry either.
  defp log_failure(%TaskComment{id: id}, reason) do
    Logger.warning("notification #{@event_type} not emitted for comment #{id}: #{reason}")
    :ok
  end
end
