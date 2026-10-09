defmodule Kanban.Webhooks.TransportTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.Transport

  defp resolved(url, addresses), do: %{uri: URI.parse(url), addresses: addresses}

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
end
