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

  `stride_list_tasks` in the full view is bounded by a byte budget (W2327):
  whole tasks average a few KB each, so a 200-task page would flood an MCP
  client's context in one call. After the shared `TaskActions.list_page/2`
  call — so board scoping and argument validation still run first — the page's
  rows are kept in id order while the encoded JSON bytes of the kept rows stay
  within `full_view_byte_budget/0` (see `fit_page/2`). The first row is always
  kept, so a non-empty page never comes back empty and paging cannot stall. The
  full view's `meta` always carries `truncated`; when rows were dropped it is
  `true` and `next_cursor` points after the last returned task, so following it
  (with the same filters) reaches every task. The slim view and the REST
  endpoint are never cut and their bodies are unchanged.
  """

  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskCommentJSON
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskJSON
  alias KanbanWeb.API.TaskListParams
  alias KanbanWeb.MCP.SchemaValidator
  alias KanbanWeb.MCP.ToolSchemas

  # Integer arguments the shared REST parsing reads as query-string text.
  @stringified_args ["id", "limit", "assigned_to_id", "column_id"]

  # The most encoded task JSON (bytes) one full-view stride_list_tasks page
  # returns. ToolSchemas and docs/MCP.md state the same figure.
  @full_view_byte_budget 100_000

  @doc "The tool definitions returned by `tools/list`."
  def definitions, do: ToolSchemas.all()

  @doc "The byte budget of task JSON in one full-view `stride_list_tasks` page."
  def full_view_byte_budget, do: @full_view_byte_budget

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
    conn |> TaskActions.list_page(args) |> render_list()
  end

  defp run("stride_add_comment", args, conn) do
    case TaskActions.add_comment(conn, args["id"], args["content"], args["agent_name"]) do
      {:ok, comment} -> success(TaskCommentJSON.show(%{comment: comment}))
      {:error, reason} -> failure(reason)
    end
  end

  defp render({:ok, template, assigns}), do: success(render_json(template, Map.new(assigns)))
  defp render({:error, reason}), do: failure(reason)

  defp render_json(:show, assigns), do: TaskJSON.show(assigns)
  defp render_json(:ack, assigns), do: TaskJSON.ack(assigns)
  defp render_json(:index, assigns), do: TaskJSON.index(assigns)

  # Only a successful page is rendered here; an error renders exactly as the
  # other tools' errors do.
  defp render_list({:ok, :index, assigns}), do: assigns |> Map.new() |> render_page()
  defp render_list(result), do: render(result)

  defp render_page(%{response_view: :full} = assigns) do
    assigns |> TaskJSON.index() |> fit_page(@full_view_byte_budget) |> success()
  end

  defp render_page(assigns), do: assigns |> TaskJSON.index() |> success()

  @doc """
  Cuts a rendered full-view page `body` (`%{data: rows, meta: meta}`) to at
  most `budget` bytes of encoded row JSON, keeping rows in order.

  The first row is always kept, even when it alone exceeds the budget, so a
  non-empty page always advances. `meta.truncated` is `true` only when rows
  were dropped; `meta.next_cursor` then points after the last kept row.
  Otherwise `meta.truncated` is `false` and `meta.next_cursor` is unchanged.
  """
  def fit_page(%{data: rows, meta: meta} = body, budget) do
    kept = take_within(rows, budget)
    %{body | data: kept, meta: cut_meta(meta, kept, length(kept) < length(rows))}
  end

  defp take_within([], _budget), do: []

  defp take_within([first | rest], budget),
    do: [first | take_more(rest, budget - encoded_size(first))]

  defp take_more([row | rest], remaining) do
    size = encoded_size(row)
    if size <= remaining, do: [row | take_more(rest, remaining - size)], else: []
  end

  defp take_more([], _remaining), do: []

  defp encoded_size(row), do: row |> Jason.encode!() |> byte_size()

  defp cut_meta(meta, _kept, false), do: Map.put(meta, :truncated, false)

  defp cut_meta(meta, kept, true) do
    last_id = List.last(kept).id

    meta
    |> Map.put(:truncated, true)
    |> Map.put(:next_cursor, TaskListParams.encode_cursor(last_id))
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
