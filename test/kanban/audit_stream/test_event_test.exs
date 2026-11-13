defmodule Kanban.AuditStream.TestEventTest do
  @moduledoc """
  `Kanban.AuditStream.send_test_event/3` with every request going to a
  `Req.Test` stub on `Kanban.Webhooks.Transport`, and the fixed DNS table of
  `Kanban.AuditStreamFixtures`. The per-Organization limit is tested in
  `Kanban.AuditStream.TestEventLimitTest`, which turns the limiter on.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Adapters.Https
  alias Kanban.AuditStream.Adapters.SplunkHec
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.TestEvent
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Webhooks.Transport

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    %{organization: organization, admin: admin, scope: Scope.for_user(admin)}
  end

  # Replies `status` with `body`, reporting each decoded request body to the
  # test process. `before` runs first.
  defp stub(status, body \\ "ok", before \\ fn -> :ok end) do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      before.()
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.host, request})
      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  defp fail_with(reason) do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, {:request, conn.host, nil})
      Req.Test.transport_error(conn, reason)
    end)
  end

  defp test_events(organization) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization.id and e.action == "audit_stream_test_sent",
      order_by: e.id
    )
    |> Repo.all()
  end

  defp send_test(ctx, destination), do: AuditStream.send_test_event(ctx.scope, destination)

  describe "send_test_event/3" do
    test "delivered class on 2xx", ctx do
      destination = destination_fixture(ctx.organization, :https)
      cursor_before = Repo.get!(Cursor, destination.id)
      stub(200)

      assert {:ok, :delivered} = send_test(ctx, destination)
      assert_received {:request, "93.184.216.35", body}

      [event] = body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert %{
               "id" => "0",
               "schema" => "stride.audit.v1",
               "action" => "audit_stream_test_sent",
               "metadata" => metadata,
               "actor" => %{"user_id" => nil, "email" => nil, "in_organization" => false},
               "ip" => nil
             } = event

      assert metadata == %{}

      # It never touches the cursor, the state or the attempts.
      assert Repo.get!(Cursor, destination.id) == cursor_before
      stored = Repo.get!(Destination, destination.id)
      assert {stored.state, stored.halted_reason, stored.last_success_at} == {:healthy, nil, nil}
      assert from(a in Attempt, where: a.destination_id == ^destination.id) |> Repo.all() == []

      assert [recorded] = test_events(ctx.organization)

      assert recorded.metadata == %{
               "user_id" => ctx.admin.id,
               "organization_id" => ctx.organization.id,
               "destination_id" => destination.id,
               "outcome" => "delivered"
             }
    end

    test "each kind builds its test request with its own adapter", ctx do
      for {kind, host} <- [
            splunk_hec: "93.184.216.34",
            datadog: "93.184.216.36",
            https: "93.184.216.35"
          ] do
        destination = destination_fixture(ctx.organization, kind)
        stub(200, ~s({"text":"Success","code":0}))

        assert {kind, {:ok, :delivered}} == {kind, send_test(ctx, destination)}
        assert_received {:request, ^host, body}
        assert body =~ "audit_stream_test_sent"
        {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, destination)
      end
    end

    test "refused, timeout and unknown host all map to could_not_connect", ctx do
      destination = destination_fixture(ctx.organization, :https)

      for reason <- [:econnrefused, :timeout, :closed, :ehostunreach, :nxdomain] do
        fail_with(reason)
        assert {reason, {:ok, :could_not_connect}} == {reason, send_test(ctx, destination)}
        assert_received {:request, _host, nil}
      end

      for host <- ["nowhere.example.net", "internal.example.com", "metadata.example.com"] do
        stub(200)

        unresolved =
          destination_fixture(ctx.organization, :splunk_hec, %{
            url: "https://#{host}/services/collector/event"
          })

        assert {host, {:ok, :could_not_connect}} == {host, send_test(ctx, unresolved)}
        refute_received {:request, _host, _body}
        {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, unresolved)
      end

      outcomes = for e <- test_events(ctx.organization), do: e.metadata["outcome"]
      assert outcomes == List.duplicate("could_not_connect", 8)
    end

    test "certificate, 401 and 500 map to their classes", ctx do
      https = destination_fixture(ctx.organization, :https)

      fail_with({:tls_alert, {:unknown_ca, ~c"TLS client: unknown CA"}})
      assert {:ok, :certificate_invalid} = send_test(ctx, https)

      fail_with({:tls_alert, {:certificate_expired, ~c"TLS client: certificate expired"}})
      assert {:ok, :certificate_invalid} = send_test(ctx, https)

      # A port that does not speak TLS is a failed connection, not a
      # certificate problem.
      fail_with({:tls_alert, {:unexpected_message, ~c"TLS client: unexpected message"}})
      assert {:ok, :could_not_connect} = send_test(ctx, https)

      for status <- [401, 403] do
        stub(status, "denied: port 22 is open on 10.0.0.5")
        assert {:ok, :credentials_refused} = send_test(ctx, https)
      end

      stub(500, "stack trace with internal hostnames")
      assert {:ok, {:http_error, 500}} = send_test(ctx, https)

      stub(404)
      assert {:ok, {:http_error, 404}} = send_test(ctx, https)

      outcomes = for e <- test_events(ctx.organization), do: e.metadata["outcome"]

      assert outcomes ==
               ~w(certificate_invalid certificate_invalid could_not_connect credentials_refused credentials_refused http_error http_error)

      # The answer's body never reaches the event.
      refute ctx.organization |> test_events() |> Enum.any?(&(inspect(&1.metadata) =~ "port"))
    end

    test "Splunk codes 21 and 22 are refused credentials; a configuration error is an HTTP error",
         ctx do
      splunk = destination_fixture(ctx.organization, :splunk_hec)

      for code <- [21, 22] do
        stub(400, ~s({"text":"Invalid token","code":#{code}}))
        assert {:ok, :credentials_refused} = send_test(ctx, splunk)
      end

      stub(400, ~s({"text":"Incorrect index","code":7}))
      assert {:ok, {:http_error, 400}} = send_test(ctx, splunk)
    end

    test "a destination whose credential can't be read sends nothing", ctx do
      destination = destination_fixture(ctx.organization, :splunk_hec)
      :ok = make_unreadable!(destination, :credential)
      stub(200)

      assert {:error, :credentials_unreadable} = send_test(ctx, destination)
      refute_received {:request, _host, _body}
      assert test_events(ctx.organization) == []
    end

    test "non-org-admins and other Organizations get nothing", ctx do
      destination = destination_fixture(ctx.organization, :https)
      stub(200)

      member = user_fixture()
      organization_member_fixture(ctx.organization, member, :member)

      for scope <- [Scope.for_user(member), Scope.for_user(admin_fixture()), nil] do
        assert {:error, :unauthorized} = AuditStream.send_test_event(scope, destination)
      end

      other = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other, other_admin, :org_admin)

      assert {:error, :not_found} =
               other_admin |> Scope.for_user() |> AuditStream.send_test_event(destination)

      refute_received {:request, _host, _body}
      assert test_events(ctx.organization) == []
      assert test_events(other) == []
    end

    test "an org-admin revoked after authorizing, before the POST, sends and records nothing",
         ctx do
      stub(200)

      memberships = fn user ->
        from(m in OrganizationMember,
          where: m.organization_id == ^ctx.organization.id and m.user_id == ^user.id
        )
      end

      revocations = [
        fn user -> user |> memberships.() |> Repo.update_all(set: [role: :member]) end,
        fn user -> user |> memberships.() |> Repo.delete_all() end,
        fn user ->
          from(u in User, where: u.id == ^user.id)
          |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
        end
      ]

      # The DNS lookup is the last step before the POST; the revocation lands
      # during it, whether the lookup then succeeds or fails.
      lookups = [&Kanban.AuditStreamFixtures.resolve/1, fn _host -> {:error, :nxdomain} end]

      for revoke <- revocations, lookup <- lookups do
        admin = user_fixture()
        organization_member_fixture(ctx.organization, admin, :org_admin)
        destination = destination_fixture(ctx.organization, :https)

        resolver = fn host ->
          revoke.(admin)
          lookup.(host)
        end

        assert {:error, :unauthorized} =
                 admin
                 |> Scope.for_user()
                 |> AuditStream.send_test_event(destination, resolver: resolver)
      end

      refute_received {:request, _host, _body}
      assert test_events(ctx.organization) == []
    end

    test "a destination deleted during the send still records the test", ctx do
      destination = destination_fixture(ctx.organization, :https)
      stub(200, "ok", fn -> Destination |> Repo.get!(destination.id) |> Repo.delete!() end)

      assert {:ok, :delivered} = send_test(ctx, destination)
      assert Repo.get(Destination, destination.id) == nil
      assert [%{metadata: %{"destination_id" => id}}] = test_events(ctx.organization)
      assert id == destination.id
    end
  end

  describe "classify/2" do
    test "maps every send result to a coarse class" do
      assert TestEvent.classify({:response, %{status: 204, body: ""}}, Https) == :delivered

      assert TestEvent.classify({:response, %{status: 429, body: ""}}, Https) ==
               {:http_error, 429}

      assert TestEvent.classify({:response, %{status: 413, body: ""}}, Https) ==
               {:http_error, 413}

      assert TestEvent.classify({:response, %{status: 400, body: ~s({"code":22})}}, SplunkHec) ==
               :credentials_refused

      assert TestEvent.classify({:transport_error, :crashed}, Https) == :could_not_connect
      assert TestEvent.classify({:guard_error, :blocked_address}, Https) == :could_not_connect
      assert TestEvent.classify({:guard_error, :unresolvable}, Https) == :could_not_connect

      assert TestEvent.classify(
               {:transport_error,
                %Req.TransportError{reason: {:tls_alert, {:bad_certificate, ~c""}}}},
               Https
             ) == :certificate_invalid
    end

    test "a certificate issued for another host, or failing any other path check, is invalid" do
      class = fn alert, description ->
        reason = {:tls_alert, {alert, description}}
        TestEvent.classify({:transport_error, %Req.TransportError{reason: reason}}, Https)
      end

      mismatch = ~c"TLS client: Bad Certificate\n {bad_cert,{hostname_check_failed,x}}"
      assert class.(:bad_certificate, mismatch) == :certificate_invalid

      other_path = ~c"TLS client: Handshake Failure\n {bad_cert,max_path_length_reached}"
      assert class.(:handshake_failure, other_path) == :certificate_invalid

      no_cipher = ~c"TLS client: Handshake Failure\n insufficient_security"
      assert class.(:handshake_failure, no_cipher) == :could_not_connect
      assert class.(:handshake_failure, :odd) == :could_not_connect
    end

    test "the recorded outcome drops the status" do
      assert TestEvent.outcome({:http_error, 500}) == :http_error
      assert TestEvent.outcome(:could_not_connect) == :could_not_connect
    end

    test "the synthetic event carries no real audit data" do
      event = TestEvent.event(~U[2026-11-12 10:00:00.000000Z])
      assert %AuditEvent{id: 0, action: "audit_stream_test_sent"} = event
      assert event.metadata == %{}
      assert event.actor_redacted
      assert event.actor_user_id == nil and event.ip == nil
    end
  end
end

defmodule Kanban.AuditStream.TestEventLimitTest do
  # async: false because the limiter is turned on globally here; the broad
  # suite runs with it off (config/test.exs).
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream
  alias Kanban.Webhooks.Transport

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, :request)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    %{organization: organization, scope: Scope.for_user(admin)}
  end

  defp sent(organization) do
    from(e in AuditEvent,
      where: e.organization_id == ^organization.id and e.action == "audit_stream_test_sent"
    )
    |> Repo.aggregate(:count)
  end

  test "11th test in an hour refused across delete and re-create", ctx do
    first = destination_fixture(ctx.organization, :https)
    for _n <- 1..6, do: assert({:ok, :delivered} = AuditStream.send_test_event(ctx.scope, first))
    {:ok, _deleted} = AuditStream.delete_destination(ctx.scope, first)

    # Another org-admin and a re-created destination share the limit.
    second_admin = user_fixture()
    organization_member_fixture(ctx.organization, second_admin, :org_admin)
    second_scope = Scope.for_user(second_admin)
    again = destination_fixture(ctx.organization, :https)

    for _n <- 1..4,
        do: assert({:ok, :delivered} = AuditStream.send_test_event(second_scope, again))

    for _n <- 1..10, do: assert_received(:request)

    assert {:error, {:rate_limited, retry_after_ms}} =
             AuditStream.send_test_event(ctx.scope, again)

    assert retry_after_ms > 0 and retry_after_ms <= 3_600_000
    refute_received :request
    assert sent(ctx.organization) == 10

    other = organization_fixture()
    other_admin = user_fixture()
    organization_member_fixture(other, other_admin, :org_admin)

    other_destination = destination_fixture(other, :https)

    assert {:ok, :delivered} =
             other_admin |> Scope.for_user() |> AuditStream.send_test_event(other_destination)
  end
end
