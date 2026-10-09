defmodule Kanban.Webhooks.UrlGuardTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.UrlGuard

  @public_v4 {93, 184, 216, 34}
  @public_v6 {0x2606, 0x4700, 0, 0, 0, 0, 0, 1}

  defp resolving(addresses), do: fn _host -> {:ok, addresses} end

  defp check(url, opts \\ []), do: UrlGuard.check(url, Keyword.put_new(opts, :allow_http, false))

  describe "blocked_ip?/1" do
    test "every blocked IPv4 range is refused at its first and last address" do
      for {first, last} <- [
            {{0, 0, 0, 0}, {0, 255, 255, 255}},
            {{10, 0, 0, 0}, {10, 255, 255, 255}},
            {{100, 64, 0, 0}, {100, 127, 255, 255}},
            {{127, 0, 0, 0}, {127, 255, 255, 255}},
            {{169, 254, 0, 0}, {169, 254, 255, 255}},
            {{172, 16, 0, 0}, {172, 31, 255, 255}},
            {{192, 0, 0, 0}, {192, 0, 0, 255}},
            {{192, 0, 2, 0}, {192, 0, 2, 255}},
            {{192, 168, 0, 0}, {192, 168, 255, 255}},
            {{198, 18, 0, 0}, {198, 19, 255, 255}},
            {{198, 51, 100, 0}, {198, 51, 100, 255}},
            {{203, 0, 113, 0}, {203, 0, 113, 255}},
            {{224, 0, 0, 0}, {239, 255, 255, 255}},
            {{240, 0, 0, 0}, {255, 255, 255, 255}}
          ],
          ip <- [first, last] do
        assert UrlGuard.blocked_ip?(ip), inspect(ip)
      end
    end

    test "addresses just outside the blocked IPv4 ranges are allowed" do
      for ip <- [
            {1, 1, 1, 1},
            {9, 255, 255, 255},
            {11, 0, 0, 0},
            {100, 63, 255, 255},
            {100, 128, 0, 0},
            {172, 15, 255, 255},
            {172, 32, 0, 0},
            {169, 253, 255, 255},
            {223, 255, 255, 255},
            @public_v4
          ] do
        refute UrlGuard.blocked_ip?(ip), inspect(ip)
      end
    end

    test "the blocked IPv6 ranges are refused" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFC00, 0, 0, 0, 0, 0, 0, 1},
            {0xFDFF, 0xFFFF, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFEBF, 0xFFFF, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0x2001, 0, 0x4136, 0, 0, 0, 0, 1},
            {0x64, 0xFF9B, 1, 0, 0, 0, 0, 1}
          ] do
        assert UrlGuard.blocked_ip?(ip), inspect(ip)
      end

      refute UrlGuard.blocked_ip?(@public_v6)
      refute UrlGuard.blocked_ip?({0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888})
    end

    test "only global unicast IPv6 is allowed, without its non-global parts" do
      for ip <- [
            {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
            {0x0100, 0, 0, 0, 0, 0, 0, 1},
            {0x5F00, 0, 0, 0, 0, 0, 0, 1},
            {0x1FFF, 0xFFFF, 0, 0, 0, 0, 0, 1},
            {0x4000, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0xFFFF, 0, 0x7F00, 1},
            {0, 0, 0, 0, 0xFFFF, 0, 0x5DB8, 0xD822},
            {0x2001, 0x0002, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x01FF, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
            {0x3FFF, 0x0FFF, 0, 0, 0, 0, 0, 1}
          ] do
        assert UrlGuard.blocked_ip?(ip), inspect(ip)
      end

      for ip <- [
            {0x2000, 0, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0200, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1},
            {0x3FFF, 0x1000, 0, 0, 0, 0, 0, 1},
            {0x3FFE, 0xFFFF, 0, 0, 0, 0, 0, 1}
          ] do
        refute UrlGuard.blocked_ip?(ip), inspect(ip)
      end
    end

    test "IPv4 addresses embedded in mapped, NAT64 and 6to4 addresses are checked as IPv4" do
      assert UrlGuard.blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      assert UrlGuard.blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      assert UrlGuard.blocked_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 1})
      assert UrlGuard.blocked_ip?({0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1})

      refute UrlGuard.blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
      refute UrlGuard.blocked_ip?({0x2002, 0x5DB8, 0xD822, 0, 0, 0, 0, 1})
    end

    test "anything that is not an address tuple counts as blocked" do
      for value <- [nil, "127.0.0.1", {1, 2, 3}, {256, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 0x10000}] do
        assert UrlGuard.blocked_ip?(value), inspect(value)
      end
    end
  end

  describe "check/2 with IP literals" do
    test "public IPv4 and IPv6 literals are allowed without a lookup" do
      no_lookup = fn _ -> flunk("an IP literal must not be resolved") end

      assert {:ok, %{addresses: [@public_v4]}} =
               check("https://93.184.216.34/hook", resolver: no_lookup)

      assert {:ok, %{addresses: [@public_v6]}} =
               check("https://[2606:4700::1]:8443/hook", resolver: no_lookup)
    end

    test "private and reserved literals are :blocked_address" do
      for url <- [
            "https://127.0.0.1/",
            "https://10.1.2.3/",
            "https://169.254.169.254/latest/meta-data",
            "https://0.0.0.0/",
            "https://[::1]/",
            "https://[::]/",
            "https://[fd00::1]/",
            "https://[fe80::1]/",
            "https://[::ffff:127.0.0.1]/",
            "https://[::ffff:169.254.169.254]/",
            "https://[::ffff:0:127.0.0.1]/",
            "https://[fec0::1]/",
            "https://[2001:db8::1]/"
          ] do
        assert check(url) == {:error, :blocked_address}, url
      end
    end

    test "decimal, octal, hex and shortened IPv4 forms are :invalid_host, never interpreted" do
      for url <- [
            "https://2130706433/",
            "https://0177.0.0.1/",
            "https://0x7f.0.0.1/",
            "https://0x7f000001/",
            "https://127.1/",
            "https://010.0.0.1/"
          ] do
        assert check(url, resolver: resolving([@public_v4])) == {:error, :invalid_host}, url
      end
    end
  end

  describe "check/2 with host names" do
    test "a host resolving only to public addresses is allowed" do
      assert {:ok, %{uri: %URI{host: "hooks.example.com"}, addresses: addresses}} =
               check("https://hooks.example.com/x", resolver: resolving([@public_v4, @public_v6]))

      assert addresses == [@public_v4, @public_v6]
    end

    test "a host resolving to a private address is :blocked_address" do
      assert check("https://internal.example.com/", resolver: resolving([{10, 0, 0, 5}])) ==
               {:error, :blocked_address}
    end

    test "a host resolving to both public and private addresses is :blocked_address" do
      assert check("https://mixed.example.com/",
               resolver: resolving([@public_v4, {127, 0, 0, 1}])
             ) ==
               {:error, :blocked_address}
    end

    test "a host that resolves to nothing or fails to resolve is :unresolvable" do
      assert check("https://empty.example.com/", resolver: resolving([])) ==
               {:error, :unresolvable}

      assert check("https://nx.example.com/", resolver: fn _ -> {:error, :nxdomain} end) ==
               {:error, :unresolvable}
    end

    test "the host passed to the resolver is lowercased" do
      resolver = fn host ->
        send(self(), {:resolved, host})
        {:ok, [@public_v4]}
      end

      assert {:ok, _} = check("https://Hooks.Example.COM/", resolver: resolver)
      assert_received {:resolved, "hooks.example.com"}
    end
  end

  describe "validate_syntax/2" do
    test "accepts a well-formed https URL without resolving it" do
      assert UrlGuard.validate_syntax("https://hooks.example.com/stride?x=1", allow_http: false) ==
               :ok

      assert UrlGuard.validate_syntax("https://xn--bcher-kva.example/", allow_http: false) == :ok
    end

    test "refuses http unless it is allowed" do
      assert UrlGuard.validate_syntax("http://hooks.example.com/", allow_http: false) ==
               {:error, :scheme_not_allowed}

      assert UrlGuard.validate_syntax("http://hooks.example.com/", allow_http: true) == :ok

      for url <- ["ftp://hooks.example.com/", "file:///etc/passwd", "hooks.example.com/x"] do
        assert UrlGuard.validate_syntax(url, allow_http: true) == {:error, :scheme_not_allowed},
               url
      end
    end

    test "refuses userinfo" do
      for url <- ["https://user:pass@hooks.example.com/", "https://user@hooks.example.com/"] do
        assert UrlGuard.validate_syntax(url, allow_http: false) == {:error, :userinfo_not_allowed}
      end
    end

    test "refuses malformed and unusual host names" do
      for url <- [
            "https:///path",
            "https://localhost/",
            "https://hooks.example.com./",
            "https://-bad.example.com/",
            "https://bad-.example.com/",
            "https://under_score.example.com/",
            "https://#{String.duplicate("a", 64)}.example.com/",
            "https://#{String.duplicate("a.", 127)}com/",
            "https://[::1/"
          ] do
        assert UrlGuard.validate_syntax(url, allow_http: false) in [
                 {:error, :invalid_host},
                 {:error, :invalid_url}
               ],
               url
      end
    end

    test "refuses a non-ASCII host" do
      assert UrlGuard.validate_syntax("https://bücher.example/", allow_http: false) in [
               {:error, :invalid_host},
               {:error, :invalid_url}
             ]
    end

    test "refuses an out-of-range port" do
      assert UrlGuard.validate_syntax("https://hooks.example.com:0/", allow_http: false) ==
               {:error, :invalid_port}

      assert UrlGuard.validate_syntax("https://hooks.example.com:99999/", allow_http: false) ==
               {:error, :invalid_port}
    end

    test "refuses a URL over 2048 bytes and non-strings" do
      long = "https://hooks.example.com/" <> String.duplicate("a", 2048)

      assert UrlGuard.validate_syntax(long, allow_http: false) == {:error, :too_long}
      assert UrlGuard.validate_syntax(nil) == {:error, :invalid_url}
      assert UrlGuard.validate_syntax(~c"https://hooks.example.com/") == {:error, :invalid_url}
    end
  end

  test "http_allowed?/1 is false only when force_ssl is configured" do
    refute UrlGuard.http_allowed?(force_ssl: [hsts: true])
    assert UrlGuard.http_allowed?([])
    assert UrlGuard.http_allowed?()
  end

  test "resolve/1 resolves localhost from the hosts file" do
    assert {:ok, addresses} = UrlGuard.resolve("localhost")
    assert Enum.any?(addresses, &UrlGuard.blocked_ip?/1)
  end

  test "error_message/1 has a distinct, translatable message for every refusal reason" do
    pot = File.read!("priv/gettext/errors.pot")

    messages =
      for reason <- [
            :too_long,
            :invalid_url,
            :scheme_not_allowed,
            :userinfo_not_allowed,
            :invalid_port,
            :invalid_host,
            :blocked_address,
            :unresolvable
          ] do
        message = UrlGuard.error_message(reason)
        assert pot =~ ~s(msgid "#{message}"), message
        message
      end

    assert messages == Enum.uniq(messages)
  end
end
