defmodule KanbanWeb.Plugs.AuthenticateApiToken.BoardSelector do
  @moduledoc """
  Reads the board a workspace-token request names (W2220), for
  `KanbanWeb.Plugs.AuthenticateApiToken`.

  A request names its board with the `X-Stride-Board` header or the `board_id`
  parameter (query string or body), as a board id. Either one alone is enough.
  Both may be sent when they name the same board: `"12"`, `12` and `" 12 "`
  agree. A blank value counts as absent.

  `read/1` returns `{:ok, selector}`, `:none` when neither names a board, and
  `:conflict` when they name different boards or the header is sent more than
  once. It does not check that the board exists or is usable; the selector is
  only a hint for `Kanban.ApiTokens.fetch_workspace_board/2`.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @header "x-stride-board"
  @param "board_id"

  @type selector :: integer() | String.t()

  @doc "Returns the request's board selector, `:none` or `:conflict`."
  @spec read(Plug.Conn.t()) :: {:ok, selector()} | :none | :conflict
  def read(%Plug.Conn{} = conn) do
    with {:ok, header} <- header_value(conn) do
      conn
      |> param_value()
      |> combine(header)
    end
  end

  defp header_value(conn) do
    case conn |> get_req_header(@header) |> Enum.map(&normalize/1) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _repeated -> :conflict
    end
  end

  defp param_value(%Plug.Conn{params: %{@param => value}}), do: normalize(value)
  defp param_value(_conn), do: nil

  defp combine(nil, nil), do: :none
  defp combine(param, nil), do: {:ok, param}
  defp combine(nil, header), do: {:ok, header}
  defp combine(same, same), do: {:ok, same}
  defp combine(_param, _header), do: :conflict

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
