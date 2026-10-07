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
  alias KanbanWeb.API.TaskJSON

  @doc """
  Translates a `{:error, reason}` tuple from the Tasks context into the same
  HTTP status + body the controller rendered inline. Clause order is
  significant and preserved from the controller; there is intentionally no
  catch-all — an unrecognized reason raises `FunctionClauseError` rather than
  masking a bug behind a generic 500.
  """
  def handle_task_error(conn, {:error, reason}), do: render_error(conn, reason)

  @doc """
  Renders the `error_body/1` translation of `reason` on `conn`. The single
  rendering point shared by every REST error path that goes through
  `error_body/1`, so the MCP tools (W2231) and the REST actions cannot drift.
  """
  def render_error(conn, reason) do
    {status, _code, body} = error_body(reason)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc """
  The conn-free translation of an error reason into
  `{status, code, body}` (W2231). `status` and `body` are exactly what the REST
  API renders; `code` is the stable machine-readable error code (the
  `ErrorDocs` key where one exists). Shared by `render_error/2` and the MCP
  tool layer, which reports `code` and `status` alongside the same body.

  There is intentionally no catch-all — an unrecognized reason raises
  `FunctionClauseError` rather than masking a bug behind a generic 500.
  """
  def error_body(:not_found), do: {:not_found, :not_found, %{error: "Task not found"}}

  def error_body(:forbidden),
    do: {:forbidden, :forbidden, %{error: "Task does not belong to this board"}}

  def error_body(:column_forbidden),
    do: {:forbidden, :column_forbidden, %{error: "Column does not belong to this board"}}

  def error_body({:hook_failed, hook_name, reason}),
    do: {:unprocessable_entity, :hook_validation_failed, hook_body(hook_name, reason)}

  def error_body({:completion_validation_failed, body}) do
    {:unprocessable_entity, :completion_validation_failed,
     ErrorDocs.add_docs_to_error(body, :completion_validation_failed)}
  end

  def error_body(:after_goal_not_a_goal) do
    documented(
      :unprocessable_entity,
      "after_goal can only be reported against tasks of type goal",
      :after_goal_not_a_goal
    )
  end

  def error_body(:not_authorized_after_goal) do
    documented(
      :forbidden,
      "Not authorized to finalize this goal — board write access required",
      :not_authorized_after_goal
    )
  end

  def error_body(:not_authorized_write) do
    documented(
      :forbidden,
      "Not authorized — board write access (owner or modify) required",
      :not_authorized_write
    )
  end

  def error_body(:not_authorized) do
    documented(
      :forbidden,
      "Not authorized — board membership required",
      :not_authorized
    )
  end

  def error_body(:after_goal_not_started) do
    documented(
      :unprocessable_entity,
      "Goal has no in-flight after_goal lifecycle (after_goal_status is nil)",
      :after_goal_not_started
    )
  end

  def error_body(:invalid_after_goal_result) do
    documented(
      :unprocessable_entity,
      "after_goal payload requires {exit_code: integer, output: string, duration_ms: non-negative integer}",
      :invalid_after_goal_result
    )
  end

  def error_body(:not_authorized_changed_files) do
    documented(
      :forbidden,
      "You can only update changed_files on tasks you are assigned to, or as a board reviewer with write access",
      :not_authorized_to_complete
    )
  end

  # D356: the message is a fixed string — it never echoes the request's title,
  # type or column, so the 422 reveals nothing the caller did not already send.
  def error_body(:wip_limit_reached) do
    documented(
      :unprocessable_entity,
      "WIP limit reached for this column — work and defect tasks cannot be added until a slot frees up",
      :wip_limit_reached
    )
  end

  # W2231: the remaining reasons were rendered inline by TaskController's
  # next/claim/complete actions; their bodies are moved here verbatim.
  def error_body(:no_next_task) do
    {:not_found, :no_tasks_available,
     %{error: "No tasks available in Ready column matching your capabilities"}}
  end

  def error_body({:no_tasks_available, nil}) do
    {:conflict, :no_tasks_available,
     ErrorDocs.add_docs_to_error(
       %{
         error:
           "No tasks available to claim matching your capabilities. All tasks in Ready column are either blocked, already claimed, or require capabilities you don't have."
       },
       :no_tasks_available,
       identifier: nil
     )}
  end

  def error_body({:no_tasks_available, identifier}) do
    {:conflict, :task_not_claimable,
     ErrorDocs.add_docs_to_error(
       %{
         error:
           "Task '#{identifier}' is not available to claim. It may be blocked by dependencies, already claimed, require capabilities you don't have, or not exist on this board."
       },
       :task_not_claimable,
       identifier: identifier
     )}
  end

  def error_body({:assigned_to_other_user, identifier}) do
    message =
      if identifier do
        "Task '#{identifier}' is assigned to a different user. Only the assigned user can claim it."
      else
        "This task is assigned to a different user. Only the assigned user can claim it."
      end

    {:forbidden, :assigned_to_other_user,
     ErrorDocs.add_docs_to_error(%{error: message}, :assigned_to_other_user,
       identifier: identifier
     )}
  end

  def error_body(:not_authorized_to_claim) do
    documented(
      :forbidden,
      "You do not have write access to claim tasks on this board",
      :not_authorized_to_claim
    )
  end

  def error_body(:claim_failed),
    do: {:internal_server_error, :internal_server_error, unexpected_claim_error_body()}

  def error_body(:invalid_status_for_complete) do
    documented(
      :unprocessable_entity,
      "Task must be in progress or blocked to complete",
      :invalid_status_for_complete
    )
  end

  def error_body(:not_authorized_to_complete) do
    documented(
      :forbidden,
      "You can only complete tasks that you are assigned to",
      :not_authorized_to_complete
    )
  end

  def error_body({:invalid_param, message}) when is_binary(message),
    do: documented(:bad_request, message, :invalid_param)

  def error_body(%Ecto.Changeset{} = changeset) do
    {:unprocessable_entity, :validation_error, TaskJSON.error(%{changeset: changeset})}
  end

  @doc """
  The stable, user-facing body for an unexpected claim failure. It never
  carries the underlying reason, which is logged server-side instead.
  """
  def unexpected_claim_error_body do
    %{
      error: "internal_server_error",
      message: "Failed to claim task. Please retry; if the failure persists, contact support."
    }
  end

  defp documented(status, message, doc_key),
    do: {status, doc_key, ErrorDocs.add_docs_to_error(%{error: message}, doc_key)}

  @doc """
  Renders a `%{error: message, <docs>}` body at `status`, with `ErrorDocs`
  guidance merged in for `doc_key`.
  """
  def error_response(conn, status, message, doc_key) do
    {status, _code, body} = documented(status, message, doc_key)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc """
  Renders the 422 body for a failed hook-execution validation, including the
  required-result format for the named hook.
  """
  def handle_hook_validation_error(conn, hook_name, reason) do
    render_error(conn, {:hook_failed, hook_name, reason})
  end

  defp hook_body(hook_name, reason) do
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
