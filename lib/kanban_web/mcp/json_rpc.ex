defmodule KanbanWeb.MCP.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 message classification and response builders for the MCP
  endpoint (W2231). Pure: no conn, no database.

  MCP narrows JSON-RPC in two ways that matter here: a request `id` is a
  string or an integer and never `null`, and `params`, when present, is an
  object.
  """

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @server_error -32_000

  def parse_error, do: @parse_error
  def invalid_request, do: @invalid_request
  def method_not_found, do: @method_not_found
  def invalid_params, do: @invalid_params
  def server_error, do: @server_error

  @doc """
  Classifies one decoded JSON-RPC message.

    * `{:request, id, method, params}` — a call that needs a response
    * `{:notification, method}` — a method call without an `id`
    * `:response` — a client response to a server request (ignored)
    * `{:invalid, id}` — anything else; `id` is echoed only when it is valid
  """
  def classify(%{"jsonrpc" => "2.0", "method" => method} = msg) when is_binary(method),
    do: classify_call(msg, method, Map.get(msg, "params", %{}))

  def classify(%{"jsonrpc" => "2.0", "id" => id} = msg)
      when is_map_key(msg, "result") or is_map_key(msg, "error") do
    if valid_id?(id), do: :response, else: {:invalid, nil}
  end

  def classify(msg) when is_map(msg), do: {:invalid, valid_id(msg)}
  def classify(_msg), do: {:invalid, nil}

  defp classify_call(msg, _method, params) when not (is_map(params) or is_nil(params)),
    do: {:invalid, valid_id(msg)}

  defp classify_call(msg, method, _params) when not is_map_key(msg, "id"),
    do: {:notification, method}

  defp classify_call(%{"id" => id}, method, params) when is_binary(id) or is_integer(id),
    do: {:request, id, method, params || %{}}

  defp classify_call(_msg, _method, _params), do: {:invalid, nil}

  @doc "A successful response."
  def result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  @doc "An error response; `data` is omitted when nil."
  def error(id, code, message, data \\ nil)

  def error(id, code, message, nil),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  def error(id, code, message, data),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message, data: data}}

  defp valid_id(%{"id" => id}), do: if(valid_id?(id), do: id)
  defp valid_id(_msg), do: nil

  defp valid_id?(id), do: is_binary(id) or is_integer(id)
end
