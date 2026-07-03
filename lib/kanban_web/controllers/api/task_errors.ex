defmodule KanbanWeb.API.TaskErrors do
  @moduledoc """
  Error translation and rendering for the task API, extracted from
  `KanbanWeb.API.TaskController` (W1444). Pairs with `KanbanWeb.API.ErrorDocs`.

  Unlike the pure W1443 helper modules (`ChangedFilesTransport`,
  `TaskParamFilter`), these functions take `conn` and render the HTTP error
  response directly (`put_status |> json`), because that is exactly what the
  controller error paths did inline. The status codes, error body shapes, and
  message strings are matched verbatim by API clients and the request-test
  suite, so they must not drift.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias KanbanWeb.API.ErrorDocs

  @doc """
  Translates a `{:error, reason}` tuple from the Tasks context into the same
  HTTP status + body the controller rendered inline. Clause order is
  significant and preserved from the controller; there is intentionally no
  catch-all — an unrecognized reason raises `FunctionClauseError` rather than
  masking a bug behind a generic 500.
  """
  def handle_task_error(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "Task not found"})
  end

  def handle_task_error(conn, {:error, :forbidden}) do
    conn |> put_status(:forbidden) |> json(%{error: "Task does not belong to this board"})
  end

  def handle_task_error(conn, {:error, :column_forbidden}) do
    conn |> put_status(:forbidden) |> json(%{error: "Column does not belong to this board"})
  end

  def handle_task_error(conn, {:error, {:hook_failed, hook_name, reason}}) do
    handle_hook_validation_error(conn, hook_name, reason)
  end

  def handle_task_error(conn, {:error, {:completion_validation_failed, body}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorDocs.add_docs_to_error(body, :completion_validation_failed))
  end

  def handle_task_error(conn, {:error, :after_goal_not_a_goal}) do
    error_response(
      conn,
      :unprocessable_entity,
      "after_goal can only be reported against tasks of type goal",
      :after_goal_not_a_goal
    )
  end

  def handle_task_error(conn, {:error, :after_goal_not_started}) do
    error_response(
      conn,
      :unprocessable_entity,
      "Goal has no in-flight after_goal lifecycle (after_goal_status is nil)",
      :after_goal_not_started
    )
  end

  def handle_task_error(conn, {:error, :invalid_after_goal_result}) do
    error_response(
      conn,
      :unprocessable_entity,
      "after_goal payload requires {exit_code: integer, output: string, duration_ms: non-negative integer}",
      :invalid_after_goal_result
    )
  end

  def handle_task_error(conn, {:error, :not_authorized_changed_files}) do
    error_response(
      conn,
      :forbidden,
      "You can only update changed_files on tasks you are assigned to, or as a board reviewer with write access",
      :not_authorized_to_complete
    )
  end

  @doc """
  Renders a `%{error: message, <docs>}` body at `status`, with `ErrorDocs`
  guidance merged in for `doc_key`.
  """
  def error_response(conn, status, message, doc_key) do
    conn
    |> put_status(status)
    |> json(ErrorDocs.add_docs_to_error(%{error: message}, doc_key))
  end

  @doc """
  Renders the 422 body for a failed hook-execution validation, including the
  required-result format for the named hook.
  """
  def handle_hook_validation_error(conn, hook_name, reason) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error: reason,
          hook: hook_name,
          required_format: %{
            "#{hook_name}_result" => %{
              exit_code: 0,
              output: "Hook execution output",
              duration_ms: 1234
            }
          }
        },
        :hook_validation_failed
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  @doc """
  Maps a mark_reviewed failure reason to its `{message, doc_key}` pair for
  `error_response/4`.
  """
  def mark_reviewed_error(:invalid_column),
    do: {"Task must be in Review column to mark as reviewed", :invalid_column_for_review}

  def mark_reviewed_error(:review_not_performed),
    do: {"Task must have a review status before being marked as reviewed", :review_not_performed}

  def mark_reviewed_error(:invalid_review_status),
    do:
      {"Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'",
       :invalid_review_status}

  def mark_reviewed_error(_other),
    do: {"Unexpected mark_reviewed error", :unexpected_mark_reviewed_error}

  @doc """
  Traverses a changeset's errors into a `%{field => [messages]}` map with
  interpolation applied. Used by the batch-create failure response.
  """
  def translate_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", stringify_value(value))
      end)
    end)
  end

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp stringify_value(value), do: inspect(value)
end
