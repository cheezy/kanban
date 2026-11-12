defmodule KanbanWeb.ClosingSendFileAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` double for a client that closes the connection while
  a file is being sent. It delegates every callback to
  `Plug.Adapters.Test.Conn` except `send_file/6`, which raises
  `Bandit.TransportError` with the reason the payload carries, as Bandit's
  adapter does when the socket write fails.

  `install/2` swaps a test conn's adapter for this one. The payload stays the
  test adapter's own map, plus a `:transport_error` key, so the delegated
  callbacks still see what they expect.
  """
  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn

  @doc "Makes `conn`'s next `send_file` raise a transport error with `reason`."
  def install(%Plug.Conn{adapter: {Conn, payload}} = conn, reason) do
    %{conn | adapter: {__MODULE__, Map.put(payload, :transport_error, reason)}}
  end

  @impl true
  def send_file(%{transport_error: reason}, _status, _headers, _path, _offset, _length) do
    raise Bandit.TransportError, message: "Unrecoverable error: #{reason}", error: reason
  end

  @impl true
  defdelegate send_resp(payload, status, headers, body), to: Conn

  @impl true
  defdelegate send_chunked(payload, status, headers), to: Conn

  @impl true
  defdelegate chunk(payload, body), to: Conn

  @impl true
  defdelegate read_req_body(payload, opts), to: Conn

  @impl true
  defdelegate inform(payload, status, headers), to: Conn

  @impl true
  defdelegate upgrade(payload, protocol, opts), to: Conn

  @impl true
  defdelegate push(payload, path, headers), to: Conn

  @impl true
  defdelegate get_peer_data(payload), to: Conn

  @impl true
  defdelegate get_sock_data(payload), to: Conn

  @impl true
  defdelegate get_ssl_data(payload), to: Conn

  @impl true
  defdelegate get_http_protocol(payload), to: Conn
end
