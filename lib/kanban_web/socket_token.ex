defmodule KanbanWeb.SocketToken do
  @moduledoc """
  The single-use socket tokens the Stride app connects to `/api/socket` with
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7, W2765).

  `POST /api/me/socket_token` signs one for the calling device with
  `sign/2`; `KanbanWeb.UserSocket` checks it with `verify/1` when the app
  connects. A token:

    * names one device and its user, and carries a random 128-bit id;
    * is signed with the endpoint secret under its own salt, so a device
      access token, a refresh token or any other signed token is never
      accepted in its place;
    * is valid for 60 seconds from issue;
    * connects once: `KanbanWeb.UserSocket` records a hash of its id through
      `Kanban.Devices.Nonces.use_socket_token/3`, and a second connect with
      the same token is refused.

  It is signed, not encrypted. The device and user ids in it are not secret,
  and it grants nothing but one socket connection for that device, which is
  checked again on connect.
  """

  alias Kanban.Devices.Device

  @salt "device-socket-token-v1"
  @max_age 60

  @typedoc "What a verified token names."
  @type claims :: %{device_id: pos_integer(), user_id: pos_integer(), token_id: String.t()}

  @doc "How long a socket token is valid after issue, in seconds: #{@max_age}."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Signs a new socket token for `device`. Returns the token and the time it
  expires, `#{@max_age}` seconds after issue.

  `opts` accepts `:signed_at` (unix seconds), used by tests to mint tokens of
  a given age.
  """
  @spec sign(Device.t(), keyword()) :: {String.t(), DateTime.t()}
  def sign(%Device{id: device_id, user_id: user_id}, opts \\ [])
      when is_integer(device_id) and is_integer(user_id) do
    signed_at = Keyword.get_lazy(opts, :signed_at, fn -> System.system_time(:second) end)
    token_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    data = %{"device_id" => device_id, "user_id" => user_id, "token_id" => token_id}

    token = Phoenix.Token.sign(KanbanWeb.Endpoint, @salt, data, signed_at: signed_at)
    {token, DateTime.from_unix!(signed_at + @max_age)}
  end

  @doc """
  Verifies a socket token and returns what it names.

  Returns `{:error, :expired}` for a token older than #{@max_age} seconds and
  `{:error, :invalid}` for anything else that is not a token `sign/2` made:
  a tampered token, one signed for another purpose, or a value that is not
  a string. It does not check whether the token was used before; that is
  `Kanban.Devices.Nonces.use_socket_token/3`.
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :invalid | :expired}
  def verify(token) when is_binary(token) do
    KanbanWeb.Endpoint
    |> Phoenix.Token.verify(@salt, token, max_age: @max_age)
    |> claims()
  end

  def verify(_token), do: {:error, :invalid}

  defp claims({:ok, %{"device_id" => device_id, "user_id" => user_id, "token_id" => token_id}})
       when is_integer(device_id) and is_integer(user_id) and is_binary(token_id),
       do: {:ok, %{device_id: device_id, user_id: user_id, token_id: token_id}}

  defp claims({:error, :expired}), do: {:error, :expired}
  defp claims(_other), do: {:error, :invalid}
end
