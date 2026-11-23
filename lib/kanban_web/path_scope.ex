defmodule KanbanWeb.PathScope do
  @moduledoc """
  Names the API a request path belongs to, before the router has run.

  `KanbanWeb.Plugs.Parsers` runs in the endpoint, before the router, and
  `KanbanWeb.ErrorJSON` renders errors the router never saw (a parse failure,
  or a path no route matches). Both need to know which API a path is under,
  so its errors get that API's format, headers and body. This module is the
  one place that decides it (D462).

  The segments are decoded with `URI.decode/1` before they are compared, as
  `Phoenix.Router` decodes them before matching routes, so a percent-encoded
  prefix such as `/%61pi/me` (which the router serves as `/api/me`) is in the
  same scope as `/api/me`. `URI.decode/1` leaves an escape that is not valid
  percent-encoding as it is, so such a segment is compared undecoded, again
  as the router compares it. `KanbanWeb.Plugs.MethodOverride` decodes the
  same way (D461).

  The scopes:

    * `:device_api` - `/api/me` and everything under it, the person API the
      mobile apps call
    * `:mcp` - `/api/mcp`, the MCP endpoint
    * `:api` - every other `/api` path, the agent API
    * `:scim` - `/scim` and everything under it
    * `:audit_signing_keys` - exactly `/.well-known/stride-audit-signing-keys`
    * `:oauth` - `/oauth` and everything under it, the device sign-in token
      API, except the browser's `/oauth/authorize` page and the paths under
      it, which keep the browser's 404
    * `:browser` - every other path
  """

  @type t :: :device_api | :mcp | :api | :scim | :audit_signing_keys | :oauth | :browser

  @doc """
  Returns the scope of a conn's path, or of a list of raw path segments.

  ## Examples

      iex> KanbanWeb.PathScope.of(["api", "me", "devices"])
      :device_api

      iex> KanbanWeb.PathScope.of(["%61pi", "me"])
      :device_api

      iex> KanbanWeb.PathScope.of(["oauth", "authorize"])
      :browser
  """
  @spec of(Plug.Conn.t() | [String.t()]) :: t()
  def of(%Plug.Conn{path_info: path_info}), do: of(path_info)

  def of(path_info) when is_list(path_info) do
    path_info |> Enum.map(&URI.decode/1) |> classify()
  end

  defp classify(["api", "me" | _]), do: :device_api
  defp classify(["api", "mcp"]), do: :mcp
  defp classify(["api" | _]), do: :api
  defp classify(["scim" | _]), do: :scim
  defp classify([".well-known", "stride-audit-signing-keys"]), do: :audit_signing_keys
  defp classify(["oauth", "authorize" | _]), do: :browser
  defp classify(["oauth" | _]), do: :oauth
  defp classify(_segments), do: :browser
end
