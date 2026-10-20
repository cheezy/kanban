defmodule KanbanWeb.Plugs.AuthenticateApiToken.BoardSelector do
  @moduledoc """
  Reads the board a workspace-token request names (W2220), for
  `KanbanWeb.Plugs.AuthenticateApiToken`.

  A request names its board with the `X-Stride-Board` header or the `board_id`
  parameter (query string or body), as a board id. Either one alone is enough.
  Both may be sent when they name the same board: `"12"`, `12` and `" 12 "`
  agree. A blank value counts as absent.

  `read/1` returns `{:ok, selector}`, `:none` when neither names a board, and
  `:conflict` when the request is ambiguous about its board: the header and
  the parameter name different boards, the query-string `board_id` and the
  JSON-body `board_id` name different boards, or the header or the
  query-string `board_id` is sent more than once. A repeat is a conflict even
  when the values agree, because Plug keeps only the last one and the request
  would otherwise be resolved silently. Repeats are read from the raw query
  string, since `conn.query_params` has already collapsed them.

  It does not check that the board exists or is usable; the selector is only a
  hint for `Kanban.ApiTokens.fetch_workspace_board/2`.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @header "x-stride-board"
  @param "board_id"

  @type selector :: integer() | String.t()

  @doc "Returns the request's board selector, `:none` or `:conflict`."
  @spec read(Plug.Conn.t()) :: {:ok, selector()} | :none | :conflict
  def read(%Plug.Conn{} = conn) do
    with {:ok, header} <- header_value(conn),
         :ok <- single_query_param(conn),
         {:ok, param} <- param_value(conn),
         {:ok, selector} <- agree(param, header) do
      found(selector)
    end
  end

  defp found(nil), do: :none
  defp found(selector), do: {:ok, selector}

  defp header_value(conn) do
    case conn |> get_req_header(@header) |> Enum.map(&normalize/1) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _repeated -> :conflict
    end
  end

  # Plug.Parsers merges the body over the query string, so a query board_id
  # that disagrees with the body's would be dropped without a word: compare
  # them when both were parsed.
  defp param_value(%Plug.Conn{query_params: %{@param => query}, body_params: %{@param => body}}),
    do: agree(normalize(query), normalize(body))

  defp param_value(%Plug.Conn{params: %{@param => value}}), do: {:ok, normalize(value)}
  defp param_value(_conn), do: {:ok, nil}

  # `board_id=1&board_id=2` (or `board_id[]=...` beside it) reaches
  # `conn.params` as one value, so count the raw keys.
  defp single_query_param(%Plug.Conn{query_string: query_string}) do
    count =
      query_string
      |> String.split("&")
      |> Enum.count(&board_id_key?/1)

    if count > 1, do: :conflict, else: :ok
  end

  defp board_id_key?(pair) do
    # URI.decode_www_form/1 leaves a malformed escape as it is, never raising.
    key = pair |> String.split("=", parts: 2) |> hd() |> URI.decode_www_form()
    key == @param or String.starts_with?(key, @param <> "[")
  end

  # Two selector values agree when they are equal or one is absent (nil).
  defp agree(nil, other), do: {:ok, other}
  defp agree(one, nil), do: {:ok, one}
  defp agree(same, same), do: {:ok, same}
  defp agree(_one, _other), do: :conflict

  # An integer, or the trimmed string when it is all digits (so "007" and 7
  # agree), else the trimmed string itself, which no board id matches.
  defp normalize(value) when is_integer(value), do: value

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} -> int
          _ -> trimmed
        end
    end
  end

  # Lists, maps, floats and booleans are never a board id; keep them as a
  # value that matches nothing, so they are not mistaken for "no selector".
  defp normalize(nil), do: nil
  defp normalize(value), do: inspect(value)
end
