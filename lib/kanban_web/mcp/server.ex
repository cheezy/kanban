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
  """

  alias KanbanWeb.MCP.JsonRpc
  alias KanbanWeb.MCP.Tools

  # Newest first; the first entry is offered when the client asks for a
  # version this server does not support.
  @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @max_batch 50

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

  defp handle_batch(messages, _conn) when length(messages) > @max_batch do
    {:reply, 400,
     JsonRpc.error(nil, JsonRpc.invalid_request(), "Batch exceeds #{@max_batch} messages")}
  end

  defp handle_batch(messages, conn) do
    case messages |> Enum.map(&handle_message(&1, conn)) |> Enum.reject(&is_nil/1) do
      [] -> :accepted
      responses -> {:reply, 200, responses}
    end
  end

  defp invalid_request do
    {:reply, 400, JsonRpc.error(nil, JsonRpc.invalid_request(), "Invalid Request")}
  end

  @doc """
  Handles one JSON-RPC message; returns its response, or nil when it needs
  none (a notification or a client response).
  """
  def handle_message(message, conn) do
    case JsonRpc.classify(message) do
      {:request, id, method, params} -> dispatch(id, method, params, conn)
      {:notification, _method} -> nil
      :response -> nil
      {:invalid, id} -> JsonRpc.error(id, JsonRpc.invalid_request(), "Invalid Request")
    end
  end

  defp dispatch(id, "initialize", params, _conn) do
    JsonRpc.result(id, %{
      protocolVersion: negotiate(params["protocolVersion"]),
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "stride", title: "Stride", version: server_version()},
      instructions: @instructions
    })
  end

  defp dispatch(id, "ping", _params, _conn), do: JsonRpc.result(id, %{})

  defp dispatch(id, "tools/list", _params, _conn),
    do: JsonRpc.result(id, %{tools: Tools.definitions()})

  defp dispatch(id, "tools/call", %{"name" => name} = params, conn) when is_binary(name) do
    case Map.get(params, "arguments") || %{} do
      %{} = args -> call_tool(id, name, args, conn)
      _ -> invalid_params(id, "arguments must be an object")
    end
  end

  defp dispatch(id, "tools/call", _params, _conn),
    do: invalid_params(id, "params.name must be a string")

  # The method name is attacker-controlled: matched as a string above and
  # never echoed or converted to an atom.
  defp dispatch(id, _method, _params, _conn),
    do: JsonRpc.error(id, JsonRpc.method_not_found(), "Method not found")

  defp call_tool(id, name, args, conn) do
    case Tools.call(name, args, conn) do
      {:ok, result} -> JsonRpc.result(id, result)
      {:error, :unknown_tool} -> invalid_params(id, "Unknown tool")
      {:error, {:invalid_params, messages}} -> invalid_params(id, "Invalid arguments", messages)
    end
  end

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
