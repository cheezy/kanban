defmodule Kanban.Webhooks.TransportTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.Transport

  defp resolved(url, addresses), do: %{uri: URI.parse(url), addresses: addresses}

  defp header(url), do: url |> URI.parse() |> Transport.host_header()

  test "request_options pins the URL to the approved IPv4 address" do
    opts =
      "https://hooks.example.com/stride?x=1"
      |> resolved([{93, 184, 216, 34}])
      |> Transport.request_options("{}", [{"x-a", "1"}])

    assert opts[:url] == "https://93.184.216.34/stride?x=1"
    assert opts[:connect_options] == [hostname: "hooks.example.com", timeout: 5_000]
    assert {"host", "hooks.example.com"} in opts[:headers]
    assert {"x-a", "1"} in opts[:headers]
    assert opts[:body] == "{}"
  end

  test "request_options sets an overall request_timeout only when one is given" do
    resolved = resolved("https://hooks.example.com/stride", [{93, 184, 216, 34}])

    refute resolved |> Transport.request_options("", []) |> Keyword.has_key?(:request_timeout)

    opts = Transport.request_options(resolved, "", [], request_timeout: 30_000, retry: true)
    assert opts[:request_timeout] == 30_000
    assert opts[:retry] == false
  end

  test "prefers an IPv4 address when both families resolve" do
    opts =
      "https://hooks.example.com/"
      |> resolved([{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}, {93, 184, 216, 34}])
      |> Transport.request_options("", [])

    assert opts[:url] == "https://93.184.216.34/"
  end

  test "an IPv6-only host gets a bracketed URL and keeps its host header" do
    opts =
      "https://hooks.example.com/"
      |> resolved([{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}])
      |> Transport.request_options("", [])

    assert opts[:url] == "https://[2606:4700::1]/"
    assert {"host", "hooks.example.com"} in opts[:headers]
  end

  test "a non-default port is kept in the URL and the host header" do
    opts =
      "https://hooks.example.com:8443/x"
      |> resolved([{93, 184, 216, 34}])
      |> Transport.request_options("", [])

    assert opts[:url] == "https://93.184.216.34:8443/x"
    assert {"host", "hooks.example.com:8443"} in opts[:headers]
  end

  describe "an IPv6 literal URL host" do
    @v6 {0x2606, 0x4700, 0, 0, 0, 0, 0, 1}

    test "brackets an IPv6 host with a port" do
      opts =
        "https://[2606:4700::1]:8443/hook"
        |> resolved([@v6])
        |> Transport.request_options("", [])

      assert {"host", "[2606:4700::1]:8443"} in opts[:headers]
      assert opts[:connect_options][:hostname] == "2606:4700::1"
    end

    test "brackets an IPv6 host on the default port" do
      opts =
        "https://[2606:4700::1]/hook"
        |> resolved([@v6])
        |> Transport.request_options("", [])

      assert {"host", "[2606:4700::1]"} in opts[:headers]
      assert opts[:connect_options][:hostname] == "2606:4700::1"

      assert header("http://[2606:4700::1]:80/") == "[2606:4700::1]"
    end

    test "brackets an IPv4-mapped IPv6 host" do
      assert header("https://[::ffff:192.0.2.1]:8443/") ==
               "[::ffff:192.0.2.1]:8443"
    end

    test "pins an IPv6 address in a valid URL" do
      opts =
        "https://[2606:4700::1]:8443/hook?x=1"
        |> resolved([@v6])
        |> Transport.request_options("", [])

      assert opts[:url] == "https://[2606:4700::1]:8443/hook?x=1"

      pinned = URI.parse(opts[:url])
      assert pinned.host |> String.to_charlist() |> :inet.parse_address() == {:ok, @v6}
      assert pinned.port == 8443
    end
  end

  test "leaves host names and IPv4 hosts unchanged" do
    for {url, expected} <- [
          {"https://hooks.example.com/x", "hooks.example.com"},
          {"https://hooks.example.com:8443/x", "hooks.example.com:8443"},
          {"https://93.184.216.34/x", "93.184.216.34"},
          {"https://93.184.216.34:8443/x", "93.184.216.34:8443"},
          {"http://93.184.216.34:80/x", "93.184.216.34"}
        ] do
      assert header(url) == expected, url
    end
  end

  test "host_header/1 leaves out a nil port and keeps a port when the scheme is unknown" do
    assert Transport.host_header(%URI{scheme: "https", host: "hooks.example.com", port: nil}) ==
             "hooks.example.com"

    assert Transport.host_header(%URI{scheme: "https", host: "2606:4700::1", port: nil}) ==
             "[2606:4700::1]"

    assert Transport.host_header(%URI{scheme: nil, host: "2606:4700::1", port: 8443}) ==
             "[2606:4700::1]:8443"
  end

  test "host_header/1 refuses a URI without a host" do
    no_host = URI.parse("/relative/path")
    assert no_host.host == nil

    assert_raise FunctionClauseError, ~r/Kanban\.Webhooks\.Transport\.host_header\/1/, fn ->
      Transport.host_header(no_host)
    end
  end

  test "never follows redirects, never retries, never asks for compression" do
    opts =
      "https://hooks.example.com/"
      |> resolved([{93, 184, 216, 34}])
      |> Transport.request_options("", [])

    assert opts[:redirect] == false
    assert opts[:retry] == false
    assert opts[:compressed] == false
    assert opts[:decode_body] == false
    assert opts[:receive_timeout] == 10_000
    assert opts[:plug] == {Req.Test, Transport}
  end

  test "collect/2 keeps reading until 64KB, then stops with exactly 64KB" do
    response = %Req.Response{body: ""}

    assert {:cont, {:req, %{body: "abc"}}} = Transport.collect({:data, "abc"}, {:req, response})

    big = String.duplicate("a", Transport.max_body() + 10)

    assert {:halt, {:req, %{body: body}}} = Transport.collect({:data, big}, {:req, response})
    assert byte_size(body) == Transport.max_body()
  end

  test "sanitize/1 cuts, replaces invalid UTF-8 and strips NUL bytes" do
    assert Transport.sanitize(<<"a", 0xFF, 0, "b">>) == "a�b"

    long = String.duplicate("a", Transport.max_body() + 5)
    assert byte_size(Transport.sanitize(long)) == Transport.max_body()
  end

  describe "post/3" do
    @approved %{uri: URI.parse("https://hooks.example.com/x"), addresses: [{93, 184, 216, 34}]}

    defp stub_reply(status, headers) do
      Req.Test.stub(Transport, fn conn ->
        conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
        Plug.Conn.send_resp(conn, status, "body")
      end)
    end

    test "returns the retry-after header value" do
      stub_reply(503, [{"retry-after", "120"}])

      assert {:ok, %{status: 503, body: "body", retry_after: "120"}} =
               Transport.post(@approved, "{}", [])
    end

    test "retry_after is nil when the response has none" do
      stub_reply(200, [])

      assert {:ok, %{status: 200, retry_after: nil}} =
               Transport.post(@approved, "{}", [])
    end
  end
end
