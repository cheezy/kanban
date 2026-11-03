defmodule KanbanWeb.API.AttachmentActions do
  @moduledoc """
  The checks and lookup behind an API attachment download, used today by the
  REST route `GET /api/tasks/:id/attachments/:attachment_id`
  (`KanbanWeb.API.TaskAttachmentController`). It takes the plan surface as an
  argument so the MCP `stride_get_attachment` tool
  (`KanbanWeb.MCP.AttachmentTool`, surface `:mcp`) shares it and refuses the
  same requests with the same reasons.

  `fetch_attachment/4` runs, in this fixed order, after the token pipeline
  and `KanbanWeb.API.BoardReadAccess` have checked the token and its user's
  live board access:

    1. The plan gate, `Kanban.Plans.check_board(board, :attachments, surface:
       surface)`, before any lookup, so a free board under enforcement cannot
       probe ids, and before the rate limit, so a refused board does not use
       it up. A refusal emits the one `[:kanban, :plan, :feature_refused]`
       event for the request.
    2. The `:attachment_download` rate limit (`Kanban.RateLimit`), keyed on
       the API token id only, so every request with one token shares one
       bucket. It counts every request that passes the plan gate, a `HEAD`
       and a request that ends in a `404` or `503` included.
    3. The task, by id or identifier on the token's board only
       (`KanbanWeb.API.TaskActions.fetch_task/3`). A task on another board
       and a missing task are both `:not_found` ("Task not found").
    4. The attachment id, parsed as a positive bigint without a query
       (`KanbanWeb.IdParams.parse/1`), then the attachment among the task's
       own files (`Kanban.Attachments.fetch_for_download_on_task/4`). A
       malformed, missing or other task's id is `:attachment_not_found`.

  The context checks the plan again with surface `:context`. Step 1 refused
  every locked board already, so that check passes and emits nothing; only a
  board leaving its Organization between the two checks could emit a second
  refusal, and the request is refused either way.

  Error reasons render through `KanbanWeb.API.TaskErrors.error_body/1`.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Plans
  alias Kanban.RateLimit
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.IdParams
  alias KanbanWeb.Plugs.HeadRequest

  @type reason ::
          {:plan_required, :attachments}
          | {:rate_limited, non_neg_integer()}
          | :not_found
          | :attachment_not_found
          | :not_authorized

  @doc """
  Runs the checks above for the attachment `attachment_ref` of the task
  `task_ref` (an id or identifier) on the conn's board. `surface` is `:rest`
  or `:mcp`, the plan surface a refusal is reported under. Returns
  `{:ok, task, attachment}` or `{:error, reason}`.
  """
  @spec fetch_attachment(Plug.Conn.t(), term(), term(), :rest | :mcp) ::
          {:ok, Task.t(), TaskAttachment.t()} | {:error, reason()}
  def fetch_attachment(
        %Plug.Conn{assigns: %{current_board: board}} = conn,
        task_ref,
        attachment_ref,
        surface
      )
      when surface in [:rest, :mcp] do
    with :ok <- Plans.check_board(board, :attachments, surface: surface),
         :ok <- rate_limit(conn.assigns.api_token) do
      lookup(conn, task_ref, attachment_ref)
    end
  end

  @doc """
  Emits `[:kanban, :api, :attachment_downloaded]` with the task and
  attachment ids, once the stored file is open and its bytes are about to be
  sent.
  """
  @spec record_download(Plug.Conn.t(), Task.t(), TaskAttachment.t()) :: :ok
  def record_download(conn, %Task{} = task, %TaskAttachment{} = attachment) do
    TaskActions.emit_telemetry(conn, :attachment_downloaded, %{
      task_id: task.id,
      attachment_id: attachment.id
    })

    :ok
  end

  defp task_on_board(task_ref, board) when is_binary(task_ref) or is_integer(task_ref) do
    case task_ref |> to_string() |> TaskActions.fetch_task(board, lean: true) do
      {:ok, task} -> {:ok, task}
      {:error, _not_on_board} -> {:error, :not_found}
    end
  end

  defp task_on_board(_task_ref, _board), do: {:error, :not_found}

  defp attachment_id(attachment_ref) do
    case IdParams.parse(attachment_ref) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :attachment_not_found}
    end
  end

  defp lookup(conn, task_ref, attachment_ref) do
    with {:ok, task} <- task_on_board(task_ref, conn.assigns.current_board),
         {:ok, attachment} <- attachment_of_task(conn, task, attachment_ref) do
      {:ok, task, attachment}
    end
  end

  defp rate_limit(api_token),
    do: RateLimit.check(:attachment_download, identity: "token:#{api_token.id}")

  defp attachment_of_task(conn, task, attachment_ref) do
    with {:ok, attachment_id} <- attachment_id(attachment_ref) do
      conn.assigns.current_user
      |> Scope.for_user()
      |> Attachments.fetch_for_download_on_task(task, attachment_id, via(conn))
      |> download_result()
    end
  end

  defp download_result({:ok, attachment}), do: {:ok, attachment}
  defp download_result({:error, {:plan_required, :attachments}} = refused), do: refused
  defp download_result({:error, :unauthorized}), do: {:error, :not_authorized}
  defp download_result({:error, _not_found}), do: {:error, :attachment_not_found}

  defp via(conn), do: if(HeadRequest.head?(conn), do: :head, else: :download)
end
