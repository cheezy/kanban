defmodule KanbanWeb.UserAuth.ReturnTo do
  @moduledoc """
  The page a signed-out visitor is brought back to once they sign in: the
  session's `:user_return_to`, stored by `KanbanWeb.UserAuth` when a gate
  sends a `GET` to the log-in page.

  The session is one signed cookie of at most 4096 bytes, and Plug raises
  `Plug.Conn.CookieOverflowError` when sending a larger one, so storing a
  very long path (a long query string) used to answer the visit with a 500.
  A path of more than `max_bytes/0` bytes is therefore not stored: the
  visitor still goes to the log-in page and lands on their default page
  afterwards. 2048 bytes leaves the rest of the cookie for the flash, the
  CSRF token and the two-factor marker, the same budget
  `KanbanWeb.TwoFactorPending.put_sso_link/3` keeps for the path and an SSO
  subject together.

  A page that cannot work without coming back, such as the device sign-in
  page, refuses such a request itself before the gate runs
  (`KanbanWeb.Plugs.OAuthReturnTo`).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1]

  @max_bytes 2048

  @doc "The longest path, in bytes, stored as the return-to."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Whether the request's path, query string included, fits as the return-to."
  @spec storable?(Plug.Conn.t()) :: boolean()
  def storable?(%Plug.Conn{} = conn), do: byte_size(current_path(conn)) <= @max_bytes

  @doc """
  Stores the path of a `GET` request as the return-to when it fits, and
  leaves the session alone otherwise.
  """
  @spec maybe_store(Plug.Conn.t()) :: Plug.Conn.t()
  def maybe_store(%Plug.Conn{method: "GET"} = conn) do
    if storable?(conn),
      do: put_session(conn, :user_return_to, current_path(conn)),
      else: conn
  end

  def maybe_store(%Plug.Conn{} = conn), do: conn
end
