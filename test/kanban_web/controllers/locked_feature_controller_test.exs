defmodule KanbanWeb.LockedFeatureControllerTest do
  # async: false because the rate-limit cases turn the limiter on globally; the
  # broad suite runs with it disabled (config/test.exs).
  use KanbanWeb.ConnCase, async: false

  import Kanban.TelemetryHelpers

  alias Kanban.Plans
  alias KanbanWeb.Telemetry.MetricsStorage

  @event [:kanban, :plan, :locked_feature_clicked]

  describe "GET /locked/:feature signed in" do
    setup :register_and_log_in_user

    test "emits locked_feature_clicked with only the feature and redirects to /pricing#contact",
         %{conn: conn} do
      attach_telemetry(@event)

      conn = get(conn, ~p"/locked/audit")

      assert redirected_to(conn) == "/pricing#contact"
      assert_receive {:telemetry_event, @event, %{count: 1}, metadata}
      assert metadata == %{feature: :audit}
    end

    test "every feature in Kanban.Plans.features/0 is counted under its own atom", %{conn: conn} do
      attach_telemetry(@event)

      for feature <- Plans.features() do
        conn = get(conn, ~p"/locked/#{Atom.to_string(feature)}")

        assert redirected_to(conn) == "/pricing#contact"
        assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: ^feature}}
      end
    end

    test "an unknown feature redirects to /pricing and emits nothing", %{conn: conn} do
      attach_telemetry(@event)

      for name <- ["billing", "Audit", " audit", "audit%00", String.duplicate("a", 300)] do
        conn = get(conn, "/locked/" <> URI.encode_www_form(name))

        assert redirected_to(conn) == "/pricing"
      end

      refute_received {:telemetry_event, @event, _measurements, _metadata}
    end
  end

  describe "GET /locked/:feature signed out" do
    test "sends the visitor to log in and emits nothing", %{conn: conn} do
      attach_telemetry(@event)

      conn = get(conn, ~p"/locked/audit")

      assert redirected_to(conn) =~ "/users/log-in"
      refute_received {:telemetry_event, @event, _measurements, _metadata}
    end
  end

  describe "GET /locked/:feature rate limit" do
    setup :register_and_log_in_user

    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)
      Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)
      :ok
    end

    test "a repeat click on the same feature is not counted but still redirects", %{conn: conn} do
      attach_telemetry(@event)

      conn = get(conn, ~p"/locked/sso")
      assert redirected_to(conn) == "/pricing#contact"
      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :sso}}

      conn = get(conn, ~p"/locked/sso")

      assert redirected_to(conn) == "/pricing#contact"
      refute_received {:telemetry_event, @event, _measurements, _metadata}
    end

    test "the same user's click on another feature still counts", %{conn: conn} do
      attach_telemetry(@event)

      get(conn, ~p"/locked/sso")
      get(conn, ~p"/locked/sso")
      get(conn, ~p"/locked/mcp")

      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :sso}}
      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :mcp}}
      refute_received {:telemetry_event, @event, _measurements, _metadata}
    end

    test "the limit is per user, so another user's click still counts", %{conn: conn} do
      attach_telemetry(@event)

      for _ <- 1..3, do: get(conn, ~p"/locked/mcp")
      assert_receive {:telemetry_event, @event, _, %{feature: :mcp}}
      refute_received {:telemetry_event, @event, _measurements, _metadata}

      %{conn: other_conn} = register_and_log_in_user(%{conn: build_conn()})
      other_conn = get(other_conn, ~p"/locked/mcp")

      assert redirected_to(other_conn) == "/pricing#contact"
      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :mcp}}
    end
  end

  describe "GET /locked/:feature cross-site requests" do
    setup :register_and_log_in_user

    test "a cross-site or same-site navigation redirects but is not counted", %{conn: conn} do
      attach_telemetry(@event)

      for site <- ["cross-site", "same-site", "something-else"] do
        response =
          conn
          |> put_req_header("sec-fetch-site", site)
          |> get(~p"/locked/audit")

        assert redirected_to(response) == "/pricing#contact"
      end

      refute_received {:telemetry_event, @event, _measurements, _metadata}
    end

    test "a same-origin or user-typed navigation is counted", %{conn: conn} do
      attach_telemetry(@event)

      for {site, feature} <- [{"same-origin", "audit"}, {"none", "telemetry"}] do
        response =
          conn
          |> put_req_header("sec-fetch-site", site)
          |> get(~p"/locked/#{feature}")

        assert redirected_to(response) == "/pricing#contact"
      end

      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :audit}}
      assert_receive {:telemetry_event, @event, %{count: 1}, %{feature: :telemetry}}
    end
  end

  describe "the stored metric" do
    test "kanban.plan.locked_feature_clicked.count is a persisted counter tagged by feature" do
      metric =
        Enum.find(
          KanbanWeb.Telemetry.metrics(),
          &(&1.name == [:kanban, :plan, :locked_feature_clicked, :count])
        ) || flunk("no kanban.plan.locked_feature_clicked.count metric")

      assert %Telemetry.Metrics.Counter{tags: [:feature]} = metric
      assert MetricsStorage.__persist__?(metric)
    end
  end
end
