defmodule KanbanWeb.OrgLive.AuditStreamingTest do
  @moduledoc """
  The org-admin Audit streaming page at `/org/audit/streaming` (W2716). Test
  events go to a `Req.Test` stub on `Kanban.Webhooks.Transport` and the fixed
  DNS table of `Kanban.AuditStreamFixtures`. The configured maximum and the
  test-event limit change global settings, so they are tested in
  `KanbanWeb.OrgLive.AuditStreamingGlobalTest` below.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  @refusal "You must be an org-admin of an Organization to access this page."
  @three_days_ago DateTime.add(DateTime.utc_now(), -3 * 86_400 - 60, :second)

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org: org, org_admin: org_admin}
  end

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  defp set(destination, fields) do
    from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)
    Repo.get!(Destination, destination.id)
  end

  defp own_txid do
    %{rows: [[txid]]} = Repo.query!("SELECT pg_current_xact_id()::text::bigint")
    txid
  end

  # An audit event of `org` in this test's open transaction: above the
  # horizon, after every fixture cursor, so it is waiting.
  defp waiting_event!(org) do
    Repo.query!(
      """
      INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
      VALUES ('organization_updated', $1, '{}', now(), $2)
      """,
      [org.id, own_txid()]
    )
  end

  # Leaves exactly `n` events waiting for `destination`, the oldest from
  # @three_days_ago: the cursor moves to the newest event so far, then `n`
  # events of `destination`'s Organization are written after it.
  defp exactly_waiting!(destination, n) do
    %{rows: [[max_id]]} = Repo.query!("SELECT coalesce(max(id), 0) FROM audit_events")

    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(set: [last_txid: own_txid(), last_event_id: max_id])

    for _n <- 1..n do
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', $2, $3)
        """,
        [destination.organization_id, DateTime.to_naive(@three_days_ago), own_txid()]
      )
    end

    destination
  end

  # Moves the cursor past every event this test's transaction can write.
  defp up_to_date!(destination) do
    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(set: [last_txid: own_txid() + 1, last_event_id: 0])
  end

  defp stub(status) do
    Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, status, "port 22 open on 10.0.0.5"))
  end

  describe "the destination list" do
    test "each row's name links to the destination page", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(
               lv,
               ~s(#destination-link-#{destination.id}[href="/org/audit/streaming/#{destination.id}"]),
               destination.name
             )

      assert {:ok, _page, html} =
               lv
               |> element("#destination-link-#{destination.id}")
               |> render_click()
               |> follow_redirect(conn)

      assert html =~ "destination-attempts"
    end

    test "an open gap shows its warning with events and dates; a dismissed one does not",
         %{conn: conn, org: org} do
      gapped = destination_fixture(org, :https)
      gap_fixture(gapped, %{events: 1})

      gap_fixture(gapped, %{
        reason: :too_old,
        events: 4,
        last_occurred_at: ~U[2026-10-05 01:00:00Z]
      })

      dismissed = destination_fixture(org, :https)
      gap_fixture(dismissed, %{dismissed_at: DateTime.utc_now()})
      clean = destination_fixture(org, :https)

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(
               lv,
               "#destination-gap-warning-#{gapped.id}",
               "5 events will never reach this destination (2026-10-01 to 2026-10-05 UTC)"
             )

      refute has_element?(lv, "#destination-gap-warning-#{dismissed.id}")
      refute has_element?(lv, "#destination-gap-warning-#{clean.id}")
    end

    test "an org-admin sees each destination row with hint, status pill, last delivered and behind by",
         %{conn: conn, org: org} do
      delivered = ~U[2026-11-01 09:30:00Z]
      splunk = org |> destination_fixture(:splunk_hec) |> set(last_success_at: delivered)
      datadog = destination_fixture(org, :datadog)
      https = destination_fixture(org, :https)
      waiting_event!(org)
      up_to_date!(splunk)

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      splunk_row = lv |> element("#destination-#{splunk.id}") |> render()
      assert splunk_row =~ splunk.name
      assert splunk_row =~ "Splunk"
      assert splunk_row =~ "collector.example.com"
      assert splunk_row =~ "•••• " <> splunk.credential_hint
      assert splunk_row =~ "2026-11-01 09:30:00 UTC"
      assert has_element?(lv, "#destination-status-#{splunk.id}[data-status-pill=healthy]")
      assert has_element?(lv, "#destination-behind-by-#{splunk.id}", "Up to date")

      datadog_row = lv |> element("#destination-#{datadog.id}") |> render()
      assert datadog_row =~ "Datadog"
      assert datadog_row =~ "http-intake.logs.datadoghq.eu"
      assert datadog_row =~ "•••• " <> datadog.credential_hint

      https_row = lv |> element("#destination-#{https.id}") |> render()
      assert https_row =~ "HTTPS endpoint"
      assert https_row =~ "siem.example.org"
      assert https_row =~ "•••• " <> https.url_hint
      assert has_element?(lv, "#destination-last-delivered-#{https.id}", "Never")
      assert has_element?(lv, "#destination-behind-by-#{https.id}", "waiting")
    end

    test "paused, retrying, failing and halted destinations show their state and reason",
         %{conn: conn, org: org} do
      paused = org |> destination_fixture(:https) |> set(enabled: false, state_reason: "old")

      retrying =
        org |> destination_fixture(:https) |> set(state: :retrying, state_reason: "HTTP 503")

      failing =
        org |> destination_fixture(:https) |> set(state: :failing, state_reason: "HTTP 500")

      halted =
        org
        |> destination_fixture(:https)
        |> set(halted_reason: :rejected_batch, state_reason: "HTTP 400")

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(lv, "#destination-status-#{paused.id}", "Paused")
      refute has_element?(lv, "#destination-reason-#{paused.id}")
      assert has_element?(lv, "#resume-destination-#{paused.id}")
      refute has_element?(lv, "#pause-destination-#{paused.id}")

      assert has_element?(lv, "#destination-status-#{retrying.id}", "Retrying")
      assert has_element?(lv, "#destination-reason-#{retrying.id}", "HTTP 503")
      assert has_element?(lv, "#destination-status-#{failing.id}", "Failing")
      assert has_element?(lv, "#destination-reason-#{failing.id}", "HTTP 500")
      assert has_element?(lv, "#destination-status-#{halted.id}", "Needs attention")
      assert has_element?(lv, "#destination-reason-#{halted.id}", "HTTP 400")
    end

    test "every status pill carries the line border on its soft fill", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      pill = lv |> element("#destination-status-#{destination.id}") |> render()
      assert pill =~ "background: var(--st-done-soft);"
      assert pill =~ "border: 1px solid var(--line);"
    end

    test "held-above-horizon events show as waiting, never Up to date", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)

      # Every event of this test is in its own open transaction, so all of
      # them are above the horizon; the cursor sits just below them.
      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: [last_txid: own_txid() - 1, last_event_id: 0])

      waiting_event!(org)

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      refute has_element?(lv, "#destination-behind-by-#{destination.id}", "Up to date")
      assert has_element?(lv, "#destination-behind-by-#{destination.id}", "waiting")
    end

    test "a destination with an unreadable credential renders as Needs attention with the re-enter reason",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec)
      make_unreadable!(destination, :credential)

      set(destination,
        halted_reason: :credentials_unreadable,
        state_reason: "Credentials can't be read. Enter them again."
      )

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(lv, "#destination-status-#{destination.id}", "Needs attention")

      assert has_element?(
               lv,
               "#destination-reason-#{destination.id}[data-credentials-unreadable]",
               "Credentials can't be read. Enter them again."
             )

      assert render(lv) =~ "•••• " <> destination.credential_hint
    end

    test "the list renders when a destination's secrets can't be decrypted", %{
      conn: conn,
      org: org
    } do
      destination = destination_fixture(org, :https)
      make_unreadable!(destination, :url)
      make_unreadable!(destination, :signing_secret)
      set(destination, state: :failing, state_reason: "Could not connect")

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(lv, "#destination-status-#{destination.id}", "Failing")
      assert has_element?(lv, "#destination-reason-#{destination.id}", "Could not connect")
      assert render(lv) =~ "siem.example.org"
    end

    test "no secret appears in the rendered HTML", %{conn: conn, org: org} do
      splunk = destination_fixture(org, :splunk_hec)
      datadog = destination_fixture(org, :datadog)

      https =
        destination_fixture(org, :https, %{
          credential: "bearer-credential-1234567890",
          settings: %{"format" => "ndjson", "header_name" => "X-Api-Key"}
        })

      https = Repo.get!(Destination, https.id)

      {:ok, lv, html} = live(conn, ~p"/org/audit/streaming")

      for html <- [html, render(lv)],
          secret <- [
            splunk.url,
            splunk.credential,
            datadog.credential,
            https.url,
            https.credential
          ] do
        refute html =~ secret
      end

      refute render(lv) =~ "assec_"
      refute render(lv) =~ "path-token"
    end

    test "the one-org-admin note shows with one enabled org-admin and not with two",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
      assert has_element?(lv, "#audit-streaming-one-org-admin-note")

      second = user_fixture()
      organization_member_fixture(org, second, :org_admin)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
      refute has_element?(lv, "#audit-streaming-one-org-admin-note")

      # A disabled org-admin does not count.
      second |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
      assert has_element?(lv, "#audit-streaming-one-org-admin-note")
    end

    test "the empty state and the default limit note", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(lv, "#audit-streaming-empty")
      assert has_element?(lv, "#audit-streaming-limit-note", "up to 3 destinations")
    end

    test "renders in every locale (de, en, es, fr, ja, pt, zh)", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      behind = org |> destination_fixture(:https) |> exactly_waiting!(2)

      for locale <- ~w(de en es fr ja pt zh) do
        {:ok, lv, _html} =
          conn
          |> Plug.Test.init_test_session(%{"locale" => locale})
          |> live(~p"/org/audit/streaming")

        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          checks = [
            {"#audit-streaming-title", Gettext.gettext(KanbanWeb.Gettext, "Audit streaming")},
            {"#destination-status-#{destination.id}",
             Gettext.gettext(KanbanWeb.Gettext, "Healthy")},
            {"#test-destination-#{destination.id}",
             Gettext.gettext(KanbanWeb.Gettext, "Send test event")},
            {"#audit-streaming-limit-note",
             Gettext.dngettext(
               KanbanWeb.Gettext,
               "default",
               "An Organization can have up to %{count} destination.",
               "An Organization can have up to %{count} destinations.",
               3,
               %{}
             )},
            # The Behind by plural: ja and zh have one plural form, the others two.
            {"#destination-behind-by-#{behind.id}",
             Gettext.dngettext(
               KanbanWeb.Gettext,
               "default",
               "%{count} event waiting, the oldest from %{age}",
               "%{count} events waiting, the oldest from %{age}",
               2,
               %{age: KanbanWeb.TimeAgo.format_age(@three_days_ago, :coarse)}
             )}
          ]

          if locale != "en" do
            refute Gettext.gettext(KanbanWeb.Gettext, "Send test event") == "Send test event",
                   "#{locale} lacks a translation"

            # A missing plural form falls back to the English msgid_plural.
            {_selector, behind_text} = List.last(checks)
            refute behind_text =~ "events waiting", "#{locale} lacks the Behind by plural"
          end

          for {selector, text} <- checks do
            assert has_element?(lv, selector, text), "#{locale}: #{selector}"
          end
        end)
      end
    end
  end

  describe "access" do
    test "a member, a site admin and another Organization's org-admin are refused",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)

      member = user_fixture()
      organization_member_fixture(org, member)

      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      for user <- [member, user_fixture(), admin_fixture()] do
        assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
                 live(log_in_user(conn, user), ~p"/org/audit/streaming")

        assert flash["error"] == @refusal
      end

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
      assert event.metadata["gate"] == "require_org_admin"

      # Another Organization's org-admin sees only their own (empty) list.
      {:ok, lv, html} = live(log_in_user(conn, other_admin), ~p"/org/audit/streaming")
      refute html =~ destination.name
      assert has_element?(lv, "#audit-streaming-empty")
    end

    test "an unauthenticated visitor is sent to log in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/org/audit/streaming")
    end

    test "an org-admin demoted while the page is open is refused on pause and nothing changes",
         %{conn: conn, org: org, org_admin: org_admin} do
      destination = destination_fixture(org, :https)

      for event <- ~w(pause resume delete send_test) do
        from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :org_admin])

        {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
        demote(org_admin)

        assert {:error, {:redirect, %{to: "/boards"}}} =
                 render_click(lv, event, %{"id" => "#{destination.id}"})
      end

      assert %Destination{enabled: true} = Repo.get!(Destination, destination.id)

      assert length(AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)) ==
               4
    end

    test "a crafted id naming another Organization's destination changes nothing",
         %{conn: conn} do
      other = destination_fixture(organization_fixture(), :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      for event <- ~w(pause delete) do
        assert render_click(lv, event, %{"id" => "#{other.id}"}) =~
                 "That destination no longer exists."
      end

      assert render_click(lv, "pause", %{"id" => "not-an-id"}) =~
               "That destination no longer exists."

      assert %Destination{enabled: true} = Repo.get!(Destination, other.id)
    end
  end

  describe "actions" do
    test "pause, resume and delete call the context and carry their confirmations",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      pause = lv |> element("#pause-destination-#{destination.id}") |> render()
      assert pause =~ "data-confirm=\"Pause this destination?"

      assert lv |> element("#pause-destination-#{destination.id}") |> render_click() =~
               "Destination paused."

      assert %Destination{enabled: false} = Repo.get!(Destination, destination.id)

      resume = lv |> element("#resume-destination-#{destination.id}") |> render()
      refute resume =~ "data-confirm"
      lv |> element("#resume-destination-#{destination.id}") |> render_click()
      assert %Destination{enabled: true} = Repo.get!(Destination, destination.id)

      delete = lv |> element("#delete-destination-#{destination.id}") |> render()
      assert delete =~ "Events will no longer be sent to it"
      assert delete =~ "history of attempts and gaps is deleted too"
      assert delete =~ "Nothing already in the destination tool is deleted."

      assert lv |> element("#delete-destination-#{destination.id}") |> render_click() =~
               "Destination deleted."

      refute Repo.get(Destination, destination.id)
      refute has_element?(lv, "#destination-#{destination.id}")
      assert has_element?(lv, "#audit-streaming-empty")
    end

    test "a destination deleted by another org-admin, then resumed, reloads the list",
         %{conn: conn, org: org} do
      destination = org |> destination_fixture(:https) |> set(enabled: false)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
      assert has_element?(lv, "#resume-destination-#{destination.id}")

      Repo.delete!(destination)

      assert lv |> element("#resume-destination-#{destination.id}") |> render_click() =~
               "That destination no longer exists."

      refute has_element?(lv, "#destination-#{destination.id}")
    end

    test "send test event shows a coarse result", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      results = [
        {fn -> stub(200) end, :ok, "Test event delivered"},
        {fn -> stub(503) end, :error, "The destination answered with an error (503)"},
        {fn -> stub(401) end, :error, "The destination refused the credentials"},
        {fn ->
           Req.Test.stub(Transport, &Req.Test.transport_error(&1, :econnrefused))
         end, :error, "Could not connect"}
      ]

      for {arrange, tone, message} <- results do
        arrange.()
        lv |> element("#test-destination-#{destination.id}") |> render_click()
        html = render_async(lv, 5_000)

        assert has_element?(
                 lv,
                 "#destination-test-result-#{destination.id}[data-test-result=#{tone}]",
                 message
               )

        refute html =~ "port 22"
        refute html =~ "10.0.0.5"
        refute html =~ "econnrefused"
      end
    end

    test "a second send test event while one is in flight sends nothing more",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      test_pid = self()

      Req.Test.stub(Transport, fn conn ->
        send(test_pid, {:posted, self()})

        receive do
          :go -> Plug.Conn.send_resp(conn, 200, "ok")
        after
          5_000 -> Plug.Conn.send_resp(conn, 200, "ok")
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      render_hook(lv, "send_test", %{"id" => to_string(destination.id)})
      # The send runs in a start_async task, which can take longer than the
      # default 100 ms to reach the stub when the suite runs partitioned.
      assert_receive {:posted, sender}, 5_000
      assert has_element?(lv, "#test-destination-#{destination.id}[disabled]")

      render_hook(lv, "send_test", %{"id" => to_string(destination.id)})
      refute_receive {:posted, _}, 200

      send(sender, :go)
      render_async(lv, 5_000)

      assert has_element?(
               lv,
               "#destination-test-result-#{destination.id}[data-test-result=ok]",
               "Test event delivered"
             )

      refute_received {:posted, _}
    end

    test "send test event on unreadable credentials asks for them again", %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec)
      make_unreadable!(destination, :credential)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      lv |> element("#test-destination-#{destination.id}") |> render_click()
      render_async(lv, 5_000)

      assert has_element?(
               lv,
               "#destination-test-result-#{destination.id}",
               "Credentials can't be read. Enter them again."
             )
    end

    test "send test event on a destination deleted since the page loaded reloads the list",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
      Repo.delete!(destination)

      assert lv |> element("#test-destination-#{destination.id}") |> render_click() =~
               "That destination no longer exists."
    end
  end

  describe "the Streaming buttons" do
    test "the audit log page links to /org/audit/streaming", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit")

      assert has_element?(
               lv,
               ~s(#audit-log-streaming-link[href="/org/audit/streaming"]),
               "Streaming"
             )

      assert {:ok, _lv, html} =
               lv
               |> element("#audit-log-streaming-link")
               |> render_click()
               |> follow_redirect(conn)

      assert html =~ "Audit streaming"
    end

    test "the console links to /org/audit/streaming", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org")

      assert has_element?(
               lv,
               ~s(#org-audit-streaming-link[href="/org/audit/streaming"]),
               "Audit streaming"
             )
    end
  end
end

defmodule KanbanWeb.OrgLive.AuditStreamingGlobalTest do
  # async: false because these tests change global settings: the configured
  # maximum and the test-event limiter, which the broad suite runs with off.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Webhooks.Transport

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org: org}
  end

  defp put_env(app_key, fun) do
    original = Application.get_env(:kanban, app_key)
    Application.put_env(:kanban, app_key, fun.(original || []))
    on_exit(fn -> Application.put_env(:kanban, app_key, original) end)
  end

  test "the empty state and the limit note with the configured maximum", %{conn: conn} do
    put_env(Kanban.AuditStream, &Keyword.put(&1, :max_destinations, 7))
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

    assert has_element?(lv, "#audit-streaming-empty")
    assert has_element?(lv, "#audit-streaming-limit-note", "up to 7 destinations")

    put_env(Kanban.AuditStream, &Keyword.put(&1, :max_destinations, 1))
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
    assert has_element?(lv, "#audit-streaming-limit-note", "up to 1 destination.")
  end

  test "send test event shows the limit message once the limit is reached",
       %{conn: conn, org: org} do
    put_env(Kanban.RateLimit, fn _original -> [enabled: true] end)
    Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, 200, "ok"))
    destination = destination_fixture(org, :https)
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

    for _n <- 1..10 do
      lv |> element("#test-destination-#{destination.id}") |> render_click()
      render_async(lv, 5_000)

      assert has_element?(
               lv,
               "#destination-test-result-#{destination.id}",
               "Test event delivered"
             )
    end

    lv |> element("#test-destination-#{destination.id}") |> render_click()
    render_async(lv, 5_000)

    assert has_element?(
             lv,
             "#destination-test-result-#{destination.id}[data-test-result=error]",
             "This Organization has sent as many test events as it can this hour."
           )
  end
end
