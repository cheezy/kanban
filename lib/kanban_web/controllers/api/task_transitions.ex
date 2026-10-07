defmodule KanbanWeb.API.TaskTransitions do
  @moduledoc """
  The REST-only workflow transitions of the task API — `unclaim`,
  `mark_reviewed`, `mark_done` and the `after_goal` report — split from
  `KanbanWeb.API.TaskController` to keep the controller under the module size
  guideline.

  The controller actions still fetch the task board-scoped and own the action
  flow; this module holds what runs once the task is in hand: the Tasks
  context call, the success telemetry, and the mapping of each failure reason
  onto the response the action has always rendered. (`next`, `claim` and
  `complete` are shared with the MCP tools and live in
  `KanbanWeb.API.TaskActions` instead.)

  Like `KanbanWeb.API.TaskErrors`, the `proceed_with_*` functions take `conn`
  and render; the statuses, bodies and telemetry events are exactly the ones
  the controller produced inline.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [render: 3]

  alias Kanban.Boards
  alias Kanban.Tasks
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskErrors

  @doc """
  The optional free-text unclaim reason from the request params.
  """
  # The reason is optional free text. Anything else (a JSON object, a
  # number) is dropped here rather than logged, stored or emailed.
  def unclaim_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  def unclaim_reason(_params), do: nil

  @doc """
  Releases `user`'s claim on `task` and renders the task, or the 403/422.
  """
  def proceed_with_unclaim(conn, task, user, reason) do
    case Tasks.unclaim_task(task, user, reason) do
      {:ok, task} ->
        TaskActions.emit_telemetry(conn, :task_unclaimed, %{task_id: task.id, reason: reason})
        render(conn, :show, task: task)

      {:error, :not_authorized} ->
        TaskErrors.error_response(
          conn,
          :forbidden,
          "You can only unclaim tasks that you claimed",
          :not_authorized_to_unclaim
        )

      {:error, :not_claimed} ->
        TaskErrors.error_response(
          conn,
          :unprocessable_entity,
          "Task is not currently claimed",
          :task_not_claimed
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Records `user`'s review of `task` and renders the task (with any hooks), or
  the 422.
  """
  def proceed_with_mark_reviewed(conn, task, user) do
    task
    |> Tasks.mark_reviewed(user)
    |> render_mark_reviewed_result(conn)
  end

  defp render_mark_reviewed_result({:ok, task, hooks}, conn) when is_list(hooks),
    do: render_reviewed_task(conn, task, hooks: hooks)

  defp render_mark_reviewed_result({:ok, task}, conn), do: render_reviewed_task(conn, task)

  defp render_mark_reviewed_result({:error, %Ecto.Changeset{} = changeset}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  defp render_mark_reviewed_result({:error, reason}, conn) do
    {message, code} = TaskErrors.mark_reviewed_error(reason)
    TaskErrors.error_response(conn, :unprocessable_entity, message, code)
  end

  defp render_reviewed_task(conn, task, opts \\ []) do
    event_name =
      if task.status == :completed, do: :task_marked_done, else: :task_returned_to_doing

    TaskActions.emit_telemetry(conn, event_name, %{
      task_id: task.id,
      review_status: task.review_status
    })

    render(conn, :show, [{:task, task} | opts])
  end

  @doc """
  Moves `task` from Review to Done for `user` and renders it, or the 422.
  """
  def proceed_with_mark_done(conn, task, user) do
    case Tasks.mark_done(task, user) do
      {:ok, task} ->
        TaskActions.emit_telemetry(conn, :task_marked_done, %{task_id: task.id})
        render(conn, :show, task: task)

      {:error, :invalid_column} ->
        TaskErrors.error_response(
          conn,
          :unprocessable_entity,
          "Task must be in Review column to mark as done",
          :invalid_column_for_mark_done
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Fetches the task board-scoped and requires live board-write access for the
  after_goal report.
  """
  # D108: parity with claim/complete/mark_reviewed/mark_done — require live
  # board-write access so a downgraded or leaked token cannot promote a goal to
  # Done. Cross-board scope is already enforced by fetch_and_verify_task; this is
  # the in-depth W1430 re-check the sibling endpoints apply.
  def fetch_verify_and_authorize_after_goal(id_or_identifier, board, %{id: user_id}) do
    with {:ok, task} <- TaskActions.fetch_task(id_or_identifier, board) do
      if Boards.get_user_access(board.id, user_id) in [:owner, :modify] do
        {:ok, task}
      else
        {:error, :not_authorized_after_goal}
      end
    end
  end

  @doc """
  `:ok` when `task` is a goal whose after_goal lifecycle is pending or
  succeeded; otherwise the matching error reason.
  """
  def validate_after_goal_target(%Kanban.Tasks.Task{type: :goal} = task) do
    case task.after_goal_status do
      status when status in [:pending, :succeeded] -> :ok
      _ -> {:error, :after_goal_not_started}
    end
  end

  def validate_after_goal_target(_), do: {:error, :after_goal_not_a_goal}

  @doc """
  Validates the `{exit_code, output, duration_ms}` report and stamps it with
  `reported_at`, or returns `{:error, :invalid_after_goal_result}`.
  """
  def validate_after_goal_result(%{
        "exit_code" => exit_code,
        "output" => output,
        "duration_ms" => duration_ms
      })
      when is_integer(exit_code) and is_binary(output) and is_integer(duration_ms) and
             duration_ms >= 0 do
    {:ok,
     %{
       "exit_code" => exit_code,
       "output" => output,
       "duration_ms" => duration_ms,
       "reported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  def validate_after_goal_result(_), do: {:error, :invalid_after_goal_result}

  @doc """
  Writes the after_goal `attempt` onto the goal and renders it, or the 422.
  """
  def proceed_with_after_goal(conn, task, attempt) do
    case Tasks.report_after_goal(task, attempt) do
      {:ok, updated_goal} ->
        TaskActions.emit_telemetry(conn, :after_goal_reported, %{
          task_id: updated_goal.id,
          exit_code: attempt["exit_code"]
        })

        render(conn, :show, task: updated_goal)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end
end
