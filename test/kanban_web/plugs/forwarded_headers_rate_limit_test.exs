defmodule KanbanWeb.ForwardedHeadersRateLimitTest do
  @moduledoc """
  The forwarded-header charter handed back by W2746: the per-IP limits on
  failed device-token authentications (`GET /api/me`) and on
  `POST /oauth/token` are keyed on `conn.remote_ip`, and no header a client
  can send moves it, so rotating `X-Forwarded-For`, `Forwarded`,
  `X-Real-IP`, `True-Client-IP` or `CF-Connecting-IP` never earns a fresh
  bucket. Only `Fly-Client-IP` is ever read, and only where
  `KanbanWeb.Plugs.RemoteClientIp` is told to trust it (behind the Fly edge,
  which overwrites it); that plug's own test covers both settings.
  """
  # Not async: it turns the global rate limiter on and changes the
  # RemoteClientIp trust setting.
  use KanbanWeb.ConnCase, async: false

  alias KanbanWeb.Plugs.RemoteClientIp

  @spoofable ["x-forwarded-for", "forwarded", "x-real-ip", "true-client-ip", "cf-connecting-ip"]

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    trust = Application.get_env(:kanban, RemoteClientIp)
    on_exit(fn -> restore(RemoteClientIp, trust) end)

    %{peer: {10, :rand.uniform(254), :rand.uniform(254), :rand.uniform(254)}}
  end

  defp restore(key, nil), do: Application.delete_env(:kanban, key)
  defp restore(key, value), do: Application.put_env(:kanban, key, value)

  defp spoofed(peer, n) do
    fake = "203.0.#{rem(n, 250)}.#{div(n, 250) + 1}"

    Enum.reduce(@spoofable, %{build_conn() | remote_ip: peer}, fn
      "forwarded", conn -> put_req_header(conn, "forwarded", "for=#{fake};proto=https")
      header, conn -> put_req_header(conn, header, fake)
    end)
    |> put_req_header("accept", "application/json")
  end

  for trust <- [false, true] do
    test "GET /api/me: rotating forwarded headers never dodges the limit (Fly trust #{trust})",
         %{peer: peer} do
      Application.put_env(:kanban, RemoteClientIp, trust_fly_client_ip: unquote(trust))

      statuses =
        for n <- 1..21 do
          peer
          |> spoofed(n)
          |> put_req_header("authorization", "Bearer sdat_guess-#{n}")
          |> get(~p"/api/me")
          |> Map.fetch!(:status)
        end

      # :api_token allows 20 failures a minute per address, then refuses.
      assert Enum.take(statuses, 20) == List.duplicate(401, 20)
      assert List.last(statuses) == 429
    end

    test "POST /oauth/token: rotating forwarded headers never dodges the limit (Fly trust #{trust})",
         %{peer: peer} do
      Application.put_env(:kanban, RemoteClientIp, trust_fly_client_ip: unquote(trust))

      statuses =
        for n <- 1..61 do
          peer
          |> spoofed(n)
          |> post(~p"/oauth/token", %{
            "grant_type" => "refresh_token",
            "client_id" => "stride-ios",
            "refresh_token" => "sdrt_guess-#{n}"
          })
          |> Map.fetch!(:status)
        end

      # :oauth_token allows 60 requests a minute per address.
      assert Enum.take(statuses, 60) == List.duplicate(400, 60)
      assert List.last(statuses) == 429
    end
  end
end
