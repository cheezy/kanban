defmodule KanbanWeb.MCP.Tools do
  @moduledoc """
  The MCP tools (W2231): validates a `tools/call` request's arguments against
  the tool's `inputSchema` (`KanbanWeb.MCP.ToolSchemas`) and runs it through
  `KanbanWeb.API.TaskActions` — the same functions the REST actions call — so
  a tool can never bypass a validation the REST endpoint applies.

  Results follow the MCP tool-result shape: the REST response body as JSON
  text in `content`, with `isError: false`. A failure from the shared path
  (not found, not authorized, a hook or completion-validation failure, ...)
  is a tool result with `isError: true` whose text is the REST error body plus
  `error_code` (the API error code) and `http_status` (the status REST would
  have returned). Only an unknown tool or arguments that fail the schema are
  JSON-RPC errors, which the caller (`KanbanWeb.MCP.Server`) renders.
  """

  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskJSON
  alias KanbanWeb.MCP.SchemaValidator
  alias KanbanWeb.MCP.ToolSchemas

  # Integer arguments the shared REST parsing reads as query-string text.
  @stringified_args ["id", "limit", "assigned_to_id", "column_id"]

  @doc "The tool definitions returned by `tools/list`."
  def definitions, do: ToolSchemas.all()

  @doc """
  Runs tool `name` with `args` for the token on `conn`.

  Returns `{:ok, tool_result}`, `{:error, :unknown_tool}` or
  `{:error, {:invalid_params, messages}}`.
  """
  def call(name, args, conn) do
    with {:ok, tool} <- fetch_tool(name),
         :ok <- validate_args(args, tool) do
      result = run(name, normalize(args), conn)

      TaskActions.emit_telemetry(conn, :mcp_tool_called, %{
        tool: name,
        is_error: result.isError
      })

      {:ok, result}
    end
  end

  defp fetch_tool(name) do
    case ToolSchemas.fetch(name) do
      nil -> {:error, :unknown_tool}
      tool -> {:ok, tool}
    end
  end

  defp validate_args(args, %{"inputSchema" => schema}) do
    case SchemaValidator.validate(args, schema) do
      :ok -> :ok
      {:error, messages} -> {:error, {:invalid_params, messages}}
    end
  end

  # An integral float (5.0) passed the schema as an integer; make it one, then
  # render the integer arguments the shared REST parsing reads as text.
  defp normalize(args) do
    args
    |> Map.new(fn {key, value} -> {key, integral_to_integer(value)} end)
    |> stringify_integer_args()
  end

  defp integral_to_integer(value) do
    if SchemaValidator.integral_float?(value), do: trunc(value), else: value
  end

  defp stringify_integer_args(args) do
    Enum.reduce(@stringified_args, args, fn key, acc ->
      case acc do
        %{^key => value} when is_integer(value) -> Map.put(acc, key, Integer.to_string(value))
        _ -> acc
      end
    end)
  end

  defp run("stride_next_task", args, conn),
    do: conn |> TaskActions.next_task(args) |> render()

  defp run("stride_claim_task", args, conn),
    do: conn |> TaskActions.claim(args) |> render()

  defp run("stride_complete_task", args, conn) do
    args = Map.put_new(args, "response_view", "slim")
    conn |> TaskActions.complete(args["id"], args) |> render()
  end

  defp run("stride_get_task", args, conn),
    do: conn |> TaskActions.get_task(args["id"], args) |> render()

  defp run("stride_list_tasks", args, conn) do
    args = Map.put_new(args, "response_view", "slim")
    conn |> TaskActions.list_page(args) |> render()
  end

  defp run("stride_add_comment", args, conn) do
    case TaskActions.add_comment(conn, args["id"], args["content"]) do
      {:ok, comment} -> success(%{data: comment_data(comment)})
      {:error, reason} -> failure(reason)
    end
  end

  defp render({:ok, template, assigns}), do: success(render_json(template, Map.new(assigns)))
  defp render({:error, reason}), do: failure(reason)

  defp render_json(:show, assigns), do: TaskJSON.show(assigns)
  defp render_json(:ack, assigns), do: TaskJSON.ack(assigns)
  defp render_json(:index, assigns), do: TaskJSON.index(assigns)

  defp comment_data(comment) do
    %{
      id: comment.id,
      task_id: comment.task_id,
      content: comment.content,
      inserted_at: comment.inserted_at
    }
  end

  @doc """
  A successful tool result carrying `body` as JSON text.
  """
  def success(body), do: tool_result(body, false)

  @doc """
  A failed tool result for a shared-path error `reason`: the REST error body
  plus `error_code` and `http_status`.
  """
  def failure(reason) do
    {status, code, body} = TaskErrors.error_body(reason)

    body
    |> Map.put(:error_code, Atom.to_string(code))
    |> Map.put(:http_status, Plug.Conn.Status.code(status))
    |> tool_result(true)
  end

  defp tool_result(body, is_error) do
    %{content: [%{type: "text", text: Jason.encode!(body)}], isError: is_error}
  end
end
