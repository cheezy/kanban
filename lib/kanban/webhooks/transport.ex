defmodule Kanban.Webhooks.Transport do
  @moduledoc """
  Sends one webhook HTTP request (W2227) with the protections a request to a
  user-supplied URL needs:

    * **Pinned to the approved address.** The URL's host is replaced with
      the first address `Kanban.Webhooks.UrlGuard.check/2` approved (IPv4
      first), and the original host name goes in `connect_options` for TLS
      SNI and certificate verification and in the `host` header. A DNS
      change between the check and the connection cannot reach another
      address.
    * **No redirects, no Req retries** (Oban owns retrying), no compression,
      a 10 second receive timeout and a 5 second connect timeout.
    * **A capped response body**: at most #{65_536} bytes are kept. Reading
      stops after the chunk that crosses the cap, and the rest of that chunk
      is dropped.

  Extra Req options come from `config :kanban, #{inspect(__MODULE__)},
  req_options: [...]`; the test environment uses it to route requests to a
  `Req.Test` stub.

  `connect_options` gives each webhook host name its own Finch pool under
  `Req.FinchSupervisor`, so the number of pools is bounded by the number of
  distinct webhook hosts. Req 0.7.5 cannot shut such pools down when idle
  without a deprecation warning on every request (`pool_max_idle_time`
  beside `connect_options`), so they are left at Finch's defaults.
  """

  @max_body 65_536

  @doc "The most response-body bytes read and kept."
  def max_body, do: @max_body

  @doc """
  POSTs `body` with `headers` to the address `resolved` (the result of
  `UrlGuard.check/2`) approved. Returns the status and the capped body, or
  the transport error.
  """
  @spec post(%{uri: URI.t(), addresses: [:inet.ip_address()]}, iodata(), [
          {String.t(), String.t()}
        ]) ::
          {:ok, %{status: integer(), body: binary()}} | {:error, Exception.t()}
  def post(resolved, body, headers) do
    case resolved |> request_options(body, headers) |> Req.post() do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: IO.iodata_to_binary(response_body)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  The Req options for a request to the approved address. Pure, so the
  pinning can be tested without a network.
  """
  @spec request_options(map(), iodata(), [{String.t(), String.t()}]) :: keyword()
  def request_options(%{uri: %URI{} = uri, addresses: addresses}, body, headers) do
    [
      url: pinned_url(uri, pick_address(addresses)),
      body: body,
      headers: [{"host", host_header(uri)} | headers],
      connect_options: [hostname: uri.host, timeout: 5_000],
      redirect: false,
      retry: false,
      compressed: false,
      decode_body: false,
      receive_timeout: 10_000,
      into: &collect/2
    ]
    |> Keyword.merge(configured_options())
  end

  @doc false
  # Req's `into:` callback: keeps at most @max_body bytes, then stops reading.
  def collect({:data, data}, {request, response}) do
    body = IO.iodata_to_binary([response.body, data])

    if byte_size(body) >= @max_body,
      do: {:halt, {request, %{response | body: binary_part(body, 0, @max_body)}}},
      else: {:cont, {request, %{response | body: body}}}
  end

  @doc """
  Makes a response body safe to store as text: cut to `max_body/0` bytes,
  invalid UTF-8 replaced and NUL bytes removed (Postgres `text` rejects
  both).
  """
  @spec sanitize(binary()) :: String.t()
  def sanitize(body) when is_binary(body) do
    body
    |> binary_part(0, min(byte_size(body), @max_body))
    |> String.replace_invalid()
    |> String.replace(<<0>>, "")
  end

  defp pick_address(addresses) do
    Enum.find(addresses, &(tuple_size(&1) == 4)) || List.first(addresses)
  end

  defp pinned_url(%URI{} = uri, address) do
    address_host = address |> :inet.ntoa() |> to_string()
    URI.to_string(%URI{uri | host: address_host})
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp configured_options do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
