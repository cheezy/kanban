defmodule KanbanWeb.DeviceTokenLeakTest do
  @moduledoc """
  The token leak charter handed back by W2746: a device's secrets (the
  authorization code, the PKCE verifier, access and refresh tokens) never
  reach the log, a Stride telemetry event's metadata, an audit row or an
  ErrorTracker context, across the whole device sign-in flow and its
  refusals.

  The flow runs through the endpoint with this process logging at `:debug`,
  so Phoenix's request log and Ecto's query log are captured as they would
  be in development.
  """
  # Not async: the test lowers this process's log level and captures every
  # Stride telemetry event any process emits.
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo
  alias Kanban.Telemetry.Catalog
  alias KanbanWeb.ErrorTrackerFilter

  @redirect_uri "com.stridelikeaboss.app:/oauth/callback"

  setup :register_and_log_in_user

  setup do
    events = Catalog.events() |> Enum.flat_map(&event_names/1) |> Enum.uniq()
    attach_telemetry(events, any_process: true)
    :ok
  end

  defp event_names(%{name: name, kind: :span}),
    do: [name ++ [:start], name ++ [:stop], name ++ [:exception]]

  defp event_names(%{name: name}), do: [name]

  defp api_conn,
    do: build_conn() |> put_req_header("accept", "application/json")

  defp authorize(conn) do
    params = %{
      "response_type" => "code",
      "client_id" => "stride-ios",
      "redirect_uri" => @redirect_uri,
      "code_challenge" => valid_code_challenge(),
      "code_challenge_method" => "S256",
      "state" => "leak-probe-state",
      "device_name" => "Leak probe phone",
      "device_class" => "phone",
      "decision" => "allow"
    }

    location = conn |> post(~p"/oauth/authorize", params) |> redirected_to()
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")
  end

  defp exchange(code, verifier \\ valid_code_verifier()) do
    api_conn()
    |> post(~p"/oauth/token", %{
      "grant_type" => "authorization_code",
      "client_id" => "stride-ios",
      "code" => code,
      "code_verifier" => verifier,
      "redirect_uri" => @redirect_uri,
      "platform" => "ios",
      "device_class" => "phone",
      "approval_public_key" => valid_approval_public_key()
    })
  end

  defp refresh(token) do
    api_conn()
    |> post(~p"/oauth/token", %{
      "grant_type" => "refresh_token",
      "client_id" => "stride-ios",
      "refresh_token" => token
    })
  end

  defp me(access_token) do
    api_conn()
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> get(~p"/api/me")
  end

  # The whole flow, with its refusals, returning every secret it handled.
  defp run_flow(conn) do
    [valid_code_verifier()] ++
      sign_in_rotate_and_replay(conn) ++ wrong_verifier(conn) ++ sign_out(conn)
  end

  # A sign-in, a rotation, then reuse of the used refresh token and a replay
  # of the redeemed code, which revoke the device.
  defp sign_in_rotate_and_replay(conn) do
    code = authorize(conn)
    first = code |> exchange() |> json_response(200)
    assert me(first["access_token"]).status == 200

    second = first["refresh_token"] |> refresh() |> json_response(200)
    assert_replays_refused(code, first, second)

    [code | Enum.flat_map([first, second], &[&1["access_token"], &1["refresh_token"]])]
  end

  defp assert_replays_refused(code, first, second) do
    assert refresh(first["refresh_token"]).status == 400
    assert exchange(code).status == 400
    assert me(second["access_token"]).status == 401
  end

  defp wrong_verifier(conn) do
    code = authorize(conn)
    assert exchange(code, String.duplicate("w", 43)).status == 400
    [code]
  end

  # A sign-out that also puts its token in the URL, where it is ignored.
  defp sign_out(conn) do
    code = authorize(conn)
    issued = code |> exchange() |> json_response(200)
    refresh_token = issued["refresh_token"]

    assert api_conn()
           |> post(~p"/oauth/revoke?token=#{refresh_token}", %{
             "token" => refresh_token,
             "client_id" => "stride-ios"
           })
           |> json_response(200) == %{}

    [code, issued["access_token"], refresh_token]
  end

  test "no secret reaches the log, telemetry metadata or the audit log", %{conn: conn} do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    {secrets, log} = with_log([level: :debug], fn -> run_flow(conn) end)
    Logger.configure(level: previous)

    assert length(secrets) == 10
    assert log =~ "POST /oauth/token", "the request log was not captured"

    metadata = collect_telemetry_metadata([])
    assert metadata != []

    audit_rows = Repo.all(AuditEvent) |> Enum.map(&inspect(&1.metadata))

    for secret <- secrets do
      refute log =~ secret, "a secret was logged"
      refute Enum.any?(metadata, &(&1 =~ secret)), "a secret was in telemetry metadata"
      refute Enum.any?(audit_rows, &(&1 =~ secret)), "a secret was in an audit row"
    end
  end

  test "an ErrorTracker context of a failing token request keeps no secret" do
    secret = "sdrt_error-tracker-probe-secret"

    for path <- ["/oauth/token", "/oauth/revoke", "/api/me/devices/current"] do
      context = %{
        "request.path" => path,
        "request.params" => %{
          "refresh_token" => secret,
          "token" => secret,
          "code" => secret,
          "code_verifier" => secret
        },
        "request.headers" => %{"authorization" => "[REDACTED]", "idempotency-key" => secret}
      }

      sanitized = context |> ErrorTrackerFilter.sanitize() |> inspect()
      refute sanitized =~ secret, "#{path} kept a secret"
    end
  end

  defp collect_telemetry_metadata(acc) do
    receive do
      {:telemetry_event, _event, _measurements, metadata} ->
        collect_telemetry_metadata([inspect(metadata, limit: :infinity) | acc])
    after
      0 -> acc
    end
  end
end
