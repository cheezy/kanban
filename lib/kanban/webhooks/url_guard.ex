defmodule Kanban.Webhooks.UrlGuard do
  @moduledoc """
  Decides whether a webhook URL may be delivered to (W2226), so a board owner
  cannot point the server at its own network (SSRF).

  `validate_syntax/2` checks everything that needs no DNS: length (at most
  2048 bytes), scheme, userinfo, port and host shape, and the range check for
  a host that is an IP literal. `check/2` runs those checks, resolves the
  host and refuses the URL when **any** resolved address is blocked, so a
  host resolving to both a public and a private address is refused. DNS can
  change after the endpoint is saved, so the delivery worker (W2227) must call
  `check/2` again before every attempt and connect only to the addresses it
  returns.

  Rules:

    * `https` only. `http` is also allowed outside production, which is
      detected at runtime by the endpoint's `force_ssl` setting (set only in
      `config/prod.exs`); removing that setting from production would make
      this guard accept `http` there.
    * A URL with a username or password is refused.
    * An IPv4 literal must be four plain decimal octets. Decimal, octal, hex
      and shortened forms (`2130706433`, `0177.0.0.1`, `0x7f.0.0.1`,
      `127.1`) are refused rather than interpreted.
    * A hostname must be ASCII (punycode for internationalised names), have
      at least two labels, not end in a dot, and not have an all-digit last
      label.
    * Blocked IPv4 ranges: 0/8, 10/8, 100.64/10, 127/8, 169.254/16 (which
      holds the cloud metadata address), 172.16/12, 192.0.0/24, 192.0.2/24,
      192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4 and 240/4.
    * IPv6 is allowed only in global unicast, 2000::/3, and not in its
      non-global parts: 2001::/23 (IETF protocol assignments, with Teredo
      and benchmarking), 2001:db8::/32 and 3fff::/20 (documentation). So
      ::1, fc00::/7, fe80::/10, fec0::/10, ff00::/8, 100::/64 and the
      IPv4-translated ::ffff:0:0:0/96 are all refused.
    * An IPv4 address embedded in an IPv4-mapped (::ffff:0:0/96), NAT64
      (64:ff9b::/96) or 6to4 (2002::/16) address is checked against the
      IPv4 ranges instead.
  """

  import Bitwise

  @max_length 2048
  @max_host_length 253
  @label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @global_v6 {{0x2000, 0, 0, 0, 0, 0, 0, 0}, 3}

  @blocked_v6 [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @type reason ::
          :too_long
          | :invalid_url
          | :scheme_not_allowed
          | :userinfo_not_allowed
          | :invalid_port
          | :invalid_host
          | :blocked_address
          | :unresolvable

  @doc """
  Checks the parts of `url` that need no DNS. Options: `:allow_http`
  (defaults to `http_allowed?/0`). Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_syntax(term(), keyword()) :: :ok | {:error, reason()}
  def validate_syntax(url, opts \\ []) do
    case classify(url, opts) do
      {:ok, _uri, _target} -> :ok
      error -> error
    end
  end

  @doc """
  Fully checks `url`: `validate_syntax/2`, then resolves the host and refuses
  it when any address is blocked. Options: `:allow_http`, and `:resolver`, a
  function from a hostname to `{:ok, [ip_tuple]} | {:error, term}` (defaults
  to `resolve/1`). Returns the parsed URI and the addresses it resolved to.
  """
  @spec check(term(), keyword()) ::
          {:ok, %{uri: URI.t(), addresses: [:inet.ip_address()]}} | {:error, reason()}
  def check(url, opts \\ []) do
    with {:ok, uri, target} <- classify(url, opts),
         {:ok, addresses} <- addresses(target, Keyword.get(opts, :resolver, &resolve/1)) do
      {:ok, %{uri: uri, addresses: addresses}}
    end
  end

  @doc """
  Resolves `host` to its IPv4 and IPv6 addresses through the system resolver.
  """
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(host) when is_binary(host) do
    name = String.to_charlist(host)

    case {:inet.getaddrs(name, :inet, 5_000), :inet.getaddrs(name, :inet6, 5_000)} do
      {{:error, reason}, {:error, _}} -> {:error, reason}
      {v4, v6} -> {:ok, ok_addresses(v4) ++ ok_addresses(v6)}
    end
  end

  defp ok_addresses({:ok, addresses}), do: addresses
  defp ok_addresses(_error), do: []

  @doc """
  Whether a delivery may use plain `http`: true unless the endpoint
  configuration sets `force_ssl`, which only production does.
  """
  @spec http_allowed?(keyword()) :: boolean()
  def http_allowed?(endpoint_config \\ Application.get_env(:kanban, KanbanWeb.Endpoint, [])),
    do: is_nil(endpoint_config[:force_ssl])

  @doc """
  Whether `ip` is in a blocked range. Anything that is not an IPv4 or IPv6
  address tuple counts as blocked.
  """
  @spec blocked_ip?(term()) :: boolean()
  def blocked_ip?({a, b, c, d} = ip)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: in_any?(ip, @blocked_v4, 32)

  def blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: blocked_ip?(embedded_v4(high, low))
  def blocked_ip?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: blocked_ip?(embedded_v4(high, low))
  def blocked_ip?({0x2002, high, low, _, _, _, _, _}), do: blocked_ip?(embedded_v4(high, low))

  def blocked_ip?({_, _, _, _, _, _, _, _} = ip) do
    if ip |> Tuple.to_list() |> Enum.all?(&(&1 in 0..0xFFFF)),
      do: blocked_v6?(ip),
      else: true
  end

  def blocked_ip?(_ip), do: true

  @doc """
  The changeset message for a refusal reason. The messages are listed in
  `priv/gettext/errors.pot` and translated in every locale's `errors.po`.
  """
  @spec error_message(reason()) :: String.t()
  def error_message(:too_long), do: "must be at most 2048 characters"
  def error_message(:invalid_url), do: "is not a valid URL"
  def error_message(:scheme_not_allowed), do: "must start with https://"
  def error_message(:userinfo_not_allowed), do: "must not contain a username or password"
  def error_message(:invalid_port), do: "has an invalid port"
  def error_message(:invalid_host), do: "has an invalid host name"
  def error_message(:blocked_address), do: "points to a private or reserved network address"
  def error_message(:unresolvable), do: "has a host name that could not be found"

  defp classify(url, opts) when is_binary(url) do
    with :ok <- check_length(url),
         {:ok, uri} <- parse(url),
         {:ok, target} <- check_parts(uri, opts) do
      {:ok, uri, target}
    end
  end

  defp classify(_url, _opts), do: {:error, :invalid_url}

  defp check_length(url) when byte_size(url) > @max_length, do: {:error, :too_long}
  defp check_length(_url), do: :ok

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp check_parts(uri, opts) do
    allow_http = Keyword.get_lazy(opts, :allow_http, &http_allowed?/0)

    with :ok <- check_scheme(uri.scheme, allow_http),
         :ok <- check_userinfo(uri.userinfo),
         :ok <- check_port(uri.port) do
      check_host(uri.host)
    end
  end

  defp check_scheme("https", _allow_http), do: :ok
  defp check_scheme("http", true), do: :ok
  defp check_scheme(_scheme, _allow_http), do: {:error, :scheme_not_allowed}

  defp check_userinfo(nil), do: :ok
  defp check_userinfo(_userinfo), do: {:error, :userinfo_not_allowed}

  defp check_port(port) when port in 1..65_535, do: :ok
  defp check_port(_port), do: {:error, :invalid_port}

  defp check_host(host) when host in [nil, ""], do: {:error, :invalid_host}

  defp check_host(host) do
    name = to_charlist(host)

    case {String.contains?(host, ":"), :inet.parse_ipv4strict_address(name)} do
      {true, _v4} -> ip_literal(:inet.parse_ipv6strict_address(name))
      {false, {:ok, _ip} = v4} -> ip_literal(v4)
      {false, {:error, _reason}} -> hostname(String.downcase(host))
    end
  end

  defp ip_literal({:ok, ip}) do
    if blocked_ip?(ip), do: {:error, :blocked_address}, else: {:ok, {:ip, ip}}
  end

  defp ip_literal({:error, _reason}), do: {:error, :invalid_host}

  defp hostname(host) do
    if valid_hostname?(host), do: {:ok, {:name, host}}, else: {:error, :invalid_host}
  end

  defp valid_hostname?(host) do
    labels = String.split(host, ".")

    byte_size(host) <= @max_host_length and length(labels) >= 2 and
      Enum.all?(labels, &Regex.match?(@label, &1)) and
      not (labels |> List.last() |> all_digits?())
  end

  defp all_digits?(label), do: String.match?(label, ~r/\A[0-9]+\z/)

  defp addresses({:ip, ip}, _resolver), do: {:ok, [ip]}

  defp addresses({:name, host}, resolver) do
    case resolver.(host) do
      {:ok, [_ | _] = addresses} -> refuse_blocked(addresses)
      _empty_or_error -> {:error, :unresolvable}
    end
  end

  defp refuse_blocked(addresses) do
    if Enum.any?(addresses, &blocked_ip?/1),
      do: {:error, :blocked_address},
      else: {:ok, addresses}
  end

  defp blocked_v6?(ip),
    do: not in_any?(ip, [@global_v6], 128) or in_any?(ip, @blocked_v6, 128)

  defp embedded_v4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp in_any?(ip, ranges, bits) do
    value = to_integer(ip)

    Enum.any?(ranges, fn {network, prefix} ->
      same_prefix?(value, to_integer(network), prefix, bits)
    end)
  end

  defp same_prefix?(value, network, prefix, bits),
    do: value >>> (bits - prefix) == network >>> (bits - prefix)

  defp to_integer({_, _, _, _} = ip), do: fold(ip, 8)
  defp to_integer(ip), do: fold(ip, 16)

  defp fold(ip, width), do: ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< width) + &1))
end
