defmodule KanbanWeb.MCP.Server do
  @moduledoc """
  The MCP method dispatcher behind `POST /api/mcp` (W2231).

  Implements the Model Context Protocol's Streamable HTTP transport in its
  stateless, JSON-only form: every POST carries one JSON-RPC message or a
  batch, and is answered with one JSON body — or `202 Accepted` with no body
  when it carried only notifications or responses. No session id is issued
  and no SSE stream is ever opened.

  Methods: `initialize`, `ping`, `tools/list`, `tools/call`, plus every
  notification (including `notifications/initialized`), which is accepted and
  ignored. Anything else is `-32601 Method not found`.

  ## Telemetry

  Every message is timed as one `[:kanban, :mcp, :request]` span, so a batch
  emits one span per message. Its `method` is a fixed label from
  `@method_labels`, or `:notification`, `:response` or `:unknown`; the method
  or tool name the client sent is attacker-chosen text and is never emitted.
  The stop event adds an `outcome`: `:ok`, `:invalid_request`,
  `:invalid_params`, `:unknown_method`, `:unknown_tool` or `:tool_error`. A
  body rejected before any message is read is one span with `method: :unknown`
  and outcome `:invalid_request`, or `:parse_error` (see `parse_error_reply/0`).
  """

  alias KanbanWeb.MCP.JsonRpc
  alias KanbanWeb.MCP.Tools

  # Newest first; the first entry is offered when the client asks for a
  # version this server does not support.
  @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @max_batch 50

  # The only method names that reach telemetry, as fixed labels. Any other
  # method is reported as :unknown.
  @method_labels %{
    "initialize" => :initialize,
    "ping" => :ping,
    "tools/list" => :tools_list,
    "tools/call" => :tools_call
  }

  @instructions "Stride task API. Typical loop: stride_next_task, stride_claim_task " <>
                  "(with the before_doing hook result), do the work, then " <>
                  "stride_complete_task with the hook, explorer and reviewer results. " <>
                  "Hooks run on the client, never on the server."

  @doc "The protocol versions this server can speak, newest first."
  def supported_versions, do: @supported_versions

  @doc """
  Handles a parsed request body.

  Returns `{:reply, status, body}` or `:accepted` (202, no body).
  """
  def handle_payload(%{"_json" => messages}, conn) when is_list(messages),
    do: handle_batch(messages, conn)

  def handle_payload(%{"_json" => _not_a_message}, _conn), do: invalid_request()

  def handle_payload(%{} = message, conn) when map_size(message) > 0 do
    case handle_message(message, conn) do
      nil -> :accepted
      %{error: %{code: -32_600}} = response -> {:reply, 400, response}
      response -> {:reply, 200, response}
    end
  end

  def handle_payload(_body, _conn), do: invalid_request()

  defp handle_batch([], _conn), do: invalid_request()

  defp handle_batch(messages, _conn) when length(messages) > @max_batch,
    do: invalid_request("Batch exceeds #{@max_batch} messages")

  defp handle_batch(messages, conn) do
    case messages |> Enum.map(&handle_message(&1, conn)) |> Enum.reject(&is_nil/1) do
      [] -> :accepted
      responses -> {:reply, 200, responses}
    end
  end

  defp invalid_request(message \\ "Invalid Request"),
    do: rejected(JsonRpc.invalid_request(), message, :invalid_request)

  @doc """
  The `400` reply for a body that is not valid JSON (`-32700 Parse error`).

  Lives here rather than in the controller so the rejection is timed as an
  `[:kanban, :mcp, :request]` span with outcome `:parse_error`, like every
  other rejected body.
  """
  def parse_error_reply, do: rejected(JsonRpc.parse_error(), "Parse error", :parse_error)

  # A body rejected before any message is read: one span, method :unknown.
  defp rejected(code, message, outcome) do
    Kanban.Telemetry.span([:kanban, :mcp, :request], %{method: :unknown}, fn ->
      {{:reply, 400, JsonRpc.error(nil, code, message)}, %{method: :unknown, outcome: outcome}}
    end)
  end

  @doc """
  Handles one JSON-RPC message; returns its response, or nil when it needs
  none (a notification or a client response).
  """
  def handle_message(message, conn) do
    classified = JsonRpc.classify(message)
    method = method_label(classified)

    Kanban.Telemetry.span([:kanban, :mcp, :request], %{method: method}, fn ->
      {response, outcome} = respond(classified, conn)
      {response, %{method: method, outcome: outcome}}
    end)
  end

  defp method_label({:request, _id, method, _params}),
    do: Map.get(@method_labels, method, :unknown)

  defp method_label({:notification, _method}), do: :notification
  defp method_label(:response), do: :response
  defp method_label({:invalid, _id}), do: :unknown

  # Returns {response, outcome}; the outcome is only ever reported, never sent.
  defp respond({:request, id, method, params}, conn), do: dispatch(id, method, params, conn)
  defp respond({:notification, _method}, _conn), do: {nil, :ok}
  defp respond(:response, _conn), do: {nil, :ok}

  defp respond({:invalid, id}, _conn),
    do: {JsonRpc.error(id, JsonRpc.invalid_request(), "Invalid Request"), :invalid_request}

  defp dispatch(id, "initialize", params, _conn) do
    result =
      JsonRpc.result(id, %{
        protocolVersion: negotiate(params["protocolVersion"]),
        capabilities: %{tools: %{listChanged: false}},
        serverInfo: %{name: "stride", title: "Stride", version: server_version()},
        instructions: @instructions
      })

    {result, :ok}
  end

  defp dispatch(id, "ping", _params, _conn), do: {JsonRpc.result(id, %{}), :ok}

  defp dispatch(id, "tools/list", _params, _conn),
    do: {JsonRpc.result(id, %{tools: Tools.definitions()}), :ok}

  defp dispatch(id, "tools/call", %{"name" => name} = params, conn) when is_binary(name) do
    case Map.get(params, "arguments") || %{} do
      %{} = args -> call_tool(id, name, args, conn)
      _ -> {invalid_params(id, "arguments must be an object"), :invalid_params}
    end
  end

  defp dispatch(id, "tools/call", _params, _conn),
    do: {invalid_params(id, "params.name must be a string"), :invalid_params}

  # The method name is attacker-controlled: matched as a string above and
  # never echoed, converted to an atom or reported to telemetry.
  defp dispatch(id, _method, _params, _conn),
    do: {JsonRpc.error(id, JsonRpc.method_not_found(), "Method not found"), :unknown_method}

  # The tool name is attacker-controlled too: an unknown one is reported only
  # as the :unknown_tool outcome.
  defp call_tool(id, name, args, conn) do
    case Tools.call(name, args, conn) do
      {:ok, result} ->
        {JsonRpc.result(id, result), tool_outcome(result)}

      {:error, :unknown_tool} ->
        {invalid_params(id, "Unknown tool"), :unknown_tool}

      {:error, {:invalid_params, messages}} ->
        {invalid_params(id, "Invalid arguments", messages), :invalid_params}
    end
  end

  defp tool_outcome(%{isError: true}), do: :tool_error
  defp tool_outcome(_result), do: :ok

  defp invalid_params(id, message, errors \\ nil) do
    data = if errors, do: %{errors: errors}
    JsonRpc.error(id, JsonRpc.invalid_params(), message, data)
  end

  defp negotiate(version) when version in @supported_versions, do: version
  defp negotiate(_version), do: hd(@supported_versions)

  defp server_version do
    case Application.spec(:kanban, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
