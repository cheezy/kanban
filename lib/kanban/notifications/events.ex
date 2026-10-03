defmodule Kanban.Notifications.Events do
  @moduledoc """
  Turns task lifecycle moments into `Kanban.Notifications.notify/3` calls.

  Every function here is a side effect hung off a write that has already
  committed. They never raise and always return `:ok`: a failure is logged
  with the event and task id only, so it can never change the result of the
  write that triggered it.

  Notification titles carry only the task identifier and title. Completion
  notes, summaries and other agent free text are never copied in; the event
  wording itself is rendered (and translated) from the event type when the
  inbox or email shows it.

  Dedupe keys are built from the task's `updated_at`, which has second
  precision, so retries of the same event never notify twice. Two genuinely
  distinct events for one task inside the same second (completion, review and
  re-completion within one second) would collapse into one notification.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Notifications
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  require Logger

  @write_access [:owner, :modify]
  @title_max 255

  @doc """
  Notifies every board member with write access (owner or modify) that
  `task` is waiting in Review. The user whose token completed the task is
  included: they are usually the reviewer.
  """
  @spec review_requested(Task.t()) :: :ok
  def review_requested(%Task{} = task) do
    safely(:review_requested, task, fn -> emit_review_requested(task) end)
  end

  @doc """
  Notifies `task`'s current assignee that the task was assigned to them.

  Nothing is sent when the task has no assignee or when `actor` assigned the
  task to themselves. A `nil` actor (a system change) still notifies.
  """
  @spec task_assigned(Task.t(), %{id: integer()} | nil) :: :ok
  def task_assigned(%Task{} = task, actor) do
    safely(:task_assigned, task, fn -> emit_task_assigned(task, actor) end)
  end

  @doc """
  Returns the users with owner or modify access to the board.
  """
  @spec write_access_members(pos_integer()) :: [Kanban.Accounts.User.t()]
  def write_access_members(board_id) do
    %Board{id: board_id}
    |> Boards.list_board_users()
    |> Enum.filter(&(&1.access in @write_access))
    |> Enum.map(& &1.user)
  end

  defp emit_review_requested(task) do
    board_id = board_id_for(task)
    recipients = write_access_members(board_id)
    dedupe_key = "review_requested:#{task.id}:#{unix(task.updated_at)}"

    Notifications.notify(
      :review_requested,
      recipients,
      attrs(task, board_id, "/review", dedupe_key)
    )
  end

  defp emit_task_assigned(%Task{assigned_to_id: nil}, _actor), do: :ok
  defp emit_task_assigned(%Task{assigned_to_id: id}, %{id: id}), do: :ok

  defp emit_task_assigned(%Task{assigned_to_id: assignee_id} = task, _actor) do
    board_id = board_id_for(task)
    url_path = "/boards/#{board_id}/tasks/#{task.id}/edit"
    dedupe_key = "task_assigned:#{task.id}:#{assignee_id}:#{unix(task.updated_at)}"

    Notifications.notify(
      :task_assigned,
      [%{id: assignee_id}],
      attrs(task, board_id, url_path, dedupe_key)
    )
  end

  defp attrs(task, board_id, url_path, dedupe_key) do
    %{
      title: title(task),
      url_path: url_path,
      board_id: board_id,
      task_id: task.id,
      dedupe_key: dedupe_key
    }
  end

  defp title(task) do
    [task.identifier, task.title]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
    |> String.slice(0, @title_max)
  end

  # Read the board from the database: a :column preloaded before a move in
  # the same update would be stale.
  defp board_id_for(%Task{column_id: column_id}) do
    Column
    |> where([c], c.id == ^column_id)
    |> select([c], c.board_id)
    |> Repo.one!()
  end

  defp unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp unix(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  defp safely(event, task, fun) do
    case fun.() do
      {:error, reason} -> log_failure(event, task.id, describe(reason))
      _ok -> :ok
    end
  rescue
    exception -> log_failure(event, task.id, inspect(exception.__struct__))
  end

  defp describe(%Ecto.Changeset{errors: errors}) do
    errors
    |> Keyword.keys()
    |> inspect()
  end

  defp describe(reason), do: inspect(reason)

  # Ids and an error kind only — never titles or exception messages, which
  # can carry task text.
  defp log_failure(event, task_id, reason) do
    Logger.warning("notification #{event} not emitted for task #{task_id}: #{reason}")
    :ok
  end
end
