defmodule Kanban.Webhooks.Transport do
  @moduledoc """
  Sends one webhook HTTP request (W2227) with the protections a request to a
  user-supplied URL needs:

    * **Pinned to the approved address.** The URL's host is replaced with
      the first address `Kanban.Webhooks.UrlGuard.check/2` approved (IPv4
      first), and the original host name goes in `connect_options` for TLS
      SNI and certificate verification and in the `host` header (bracketed
      when it is an IPv6 literal, see `host_header/1`). A DNS
      change between the check and the connection cannot reach another
      address.
    * **No redirects, no Req retries** (Oban owns retrying), no compression,
      a 10 second receive timeout and a 5 second connect timeout. The
      receive timeout bounds each read, not the whole response, so a caller
      that wants the response read within a deadline passes
      `request_timeout:` to `post/4`; the audit stream worker does.
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
  `UrlGuard.check/2`) approved. Returns the status, the capped body and the
  first `retry-after` response header (nil when there is none), or the
  transport error. Webhook deliveries ignore `retry_after`; the audit stream
  worker honours it.

  Options: `:request_timeout`, the most milliseconds Finch waits for the
  response once the body is sent (default: no limit). It is checked between
  reads, so a response can run over it by up to one receive timeout, and it
  covers neither connecting nor sending the body. A response over it returns
  a `Req.TransportError` with reason `:timeout`.
  """
  @spec post(
          %{uri: URI.t(), addresses: [:inet.ip_address()]},
          iodata(),
          [{String.t(), String.t()}],
          keyword()
        ) ::
          {:ok, %{status: integer(), body: binary(), retry_after: String.t() | nil}}
          | {:error, Exception.t()}
  def post(resolved, body, headers, opts \\ []) do
    case resolved |> request_options(body, headers, opts) |> Req.post() do
      {:ok, %Req.Response{status: status, body: response_body} = response} ->
        {:ok,
         %{
           status: status,
           body: IO.iodata_to_binary(response_body),
           retry_after: response |> Req.Response.get_header("retry-after") |> List.first()
         }}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  The Req options for a request to the approved address, with the
  `:request_timeout` of `opts` when one is given. Pure, so the pinning can be
  tested without a network.
  """
  @spec request_options(map(), iodata(), [{String.t(), String.t()}], keyword()) :: keyword()
  def request_options(%{uri: %URI{} = uri, addresses: addresses}, body, headers, opts \\ []) do
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
    |> Keyword.merge(Keyword.take(opts, [:request_timeout]))
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

  @doc """
  The `host` header for a request to `uri`: its host, with `:port` when the
  port is not the scheme's default. An IPv6 literal is bracketed
  (`[2606:4700::1]:8443`), as RFC 7230 section 5.4 requires, because
  `URI.parse/1` returns it without brackets. Host names and IPv4 literals are
  unchanged. Only the header is bracketed: `connect_options` keeps the bare
  host for TLS SNI and certificate verification.

  A `nil` port is left out, as for the default port. The URI must have a
  host: `Kanban.Webhooks.UrlGuard.check/2` refuses a URL without one, and
  this raises `FunctionClauseError` rather than build an empty header.
  """
  @spec host_header(URI.t()) :: String.t()
  def host_header(%URI{host: host, port: port, scheme: scheme}) when is_binary(host) do
    host = bracket_ipv6(host)
    if default_port?(scheme, port), do: host, else: "#{host}:#{port}"
  end

  defp default_port?(_scheme, nil), do: true
  defp default_port?(scheme, port) when is_binary(scheme), do: port == URI.default_port(scheme)
  defp default_port?(_scheme, _port), do: false

  defp bracket_ipv6(host) do
    case host |> String.to_charlist() |> :inet.parse_ipv6strict_address() do
      {:ok, _address} -> "[#{host}]"
      {:error, _reason} -> host
    end
  end

  defp configured_options do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
