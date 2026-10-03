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

  Dedupe keys make retries of the same event notify once:

    * review_requested and task_assigned use the task's `updated_at`, which
      has second precision, so two genuinely distinct events for one task in
      the same second (completion, review and re-completion within a second)
      collapse into one notification;
    * claim_expired uses `claim_expires_at` (a new claim gets a new key);
    * goal_completed uses the goal's `completed_at`;
    * after_goal_failed uses the index of the first failing attempt in the
      current failure streak, so a streak notifies once and a failure after
      a later success notifies again.

  Every function here must be called after the triggering write commits,
  except `goal_completed_after_commit/1`, which only enqueues a job and is
  safe inside a transaction.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Notifications
  alias Kanban.Notifications.GoalCompletedWorker
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
  Notifies a task's assigned user that their claim on it expired before the
  task was completed.
  """
  @spec claim_expired(Task.t()) :: :ok
  def claim_expired(%Task{assigned_to_id: nil}), do: :ok
  def claim_expired(%Task{claim_expires_at: nil}), do: :ok

  def claim_expired(%Task{} = task) do
    safely(:claim_expired, task, fn -> emit_claim_expired(task) end)
  end

  @doc """
  Notifies a goal's creator and assignee that the goal reached Done. Does
  nothing unless the goal is actually completed.
  """
  @spec goal_completed(Task.t()) :: :ok
  def goal_completed(%Task{type: :goal, status: :completed, completed_at: %DateTime{}} = goal) do
    safely(:goal_completed, goal, fn -> emit_goal_completed(goal) end)
  end

  def goal_completed(%Task{}), do: :ok

  @doc """
  Enqueues `Kanban.Notifications.GoalCompletedWorker` for a completed goal.
  Safe inside a transaction: the job commits or rolls back with the move and
  only notifies once the move has committed.
  """
  @spec goal_completed_after_commit(Task.t()) :: :ok
  def goal_completed_after_commit(%Task{type: :goal, status: :completed, id: id} = goal) do
    safely(:goal_completed, goal, fn ->
      %{goal_id: id}
      |> GoalCompletedWorker.new()
      |> Oban.insert()
    end)
  end

  def goal_completed_after_commit(%Task{}), do: :ok

  @doc """
  Notifies a goal's creator and assignee that its after_goal hook failed,
  once per failure streak. Only the exit code and duration are included —
  never the hook's output, which is unreviewed agent-machine text.
  """
  @spec after_goal_failed(Task.t(), map()) :: :ok
  def after_goal_failed(%Task{} = goal, attempt) when is_map(attempt) do
    safely(:after_goal_failed, goal, fn -> emit_after_goal_failed(goal, attempt) end)
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

  defp emit_claim_expired(task) do
    board_id = board_id_for(task)
    dedupe_key = "claim_expired:#{task.id}:#{unix(task.claim_expires_at)}"

    Notifications.notify(
      :claim_expired,
      [%{id: task.assigned_to_id}],
      attrs(task, board_id, task_path(board_id, task), dedupe_key)
    )
  end

  defp emit_goal_completed(goal) do
    board_id = board_id_for(goal)
    recipients = goal_recipients(goal)
    dedupe_key = "goal_completed:#{goal.id}:#{unix(goal.completed_at)}"

    Notifications.notify(
      :goal_completed,
      recipients,
      attrs(goal, board_id, task_path(board_id, goal), dedupe_key)
    )
  end

  defp emit_after_goal_failed(goal, attempt) do
    board_id = board_id_for(goal)
    recipients = goal_recipients(goal)
    streak_start = failure_streak_start(goal.after_goal_attempts || [])
    dedupe_key = "after_goal_failed:#{goal.id}:#{streak_start}"

    attrs =
      goal
      |> attrs(board_id, task_path(board_id, goal), dedupe_key)
      |> Map.merge(failure_details(attempt))

    Notifications.notify(:after_goal_failed, recipients, attrs)
  end

  defp goal_recipients(goal) do
    [goal.created_by_id, goal.assigned_to_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&%{id: &1})
  end

  defp task_path(board_id, task), do: "/boards/#{board_id}/tasks/#{task.id}/edit"

  # The streak starts right after the last successful attempt (exit code 0,
  # including the grace worker's synthetic success).
  defp failure_streak_start(attempts) do
    attempts
    |> Enum.with_index()
    |> Enum.reduce(0, fn
      {%{"exit_code" => 0}, index}, _start -> index + 1
      _attempt, start -> start
    end)
  end

  # Only the numeric exit code and duration — never the hook's output. They
  # are stored as metadata; the inbox and email render (and translate) the
  # "Exit code …" line from it at display time.
  defp failure_details(%{"exit_code" => exit_code} = attempt) when is_integer(exit_code) do
    case Map.get(attempt, "duration_ms") do
      duration when is_integer(duration) ->
        %{metadata: %{"exit_code" => exit_code, "duration_ms" => duration}}

      _missing ->
        %{metadata: %{"exit_code" => exit_code}}
    end
  end

  defp failure_details(_attempt), do: %{}

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
