defmodule KanbanWeb.OrgLive.AuditStreamDestinationTest do
  @moduledoc """
  The org-admin page of one audit stream destination at
  `/org/audit/streaming/:id` (W2718): settings, status, lag, gaps, the last
  50 attempts, signing-secret rotation, and Retry now and Skip this batch for
  a rejected batch. Events are inserted with a chosen small `txid`, below any
  real horizon, and the destination's cursor is set by hand, as in
  `Kanban.AuditStream.StatusTest`.
  """
  use KanbanWeb.ConnCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @refusal "You must be an org-admin of an Organization to access this page."
  @not_found "Destination not found."

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org: org, org_admin: org_admin}
  end

  # --- helpers ------------------------------------------------------------------

  defp path(%Destination{id: id}), do: ~p"/org/audit/streaming/#{id}"

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  defp set(destination, fields) do
    from(d in Destination, where: d.id == ^destination.id) |> Repo.update_all(set: fields)
    Repo.get!(Destination, destination.id)
  end

  defp set_cursor(destination, fields),
    do:
      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: fields)

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp event!(org, txid, inserted_at) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', $2, $3) RETURNING id
        """,
        [org.id, inserted_at, txid]
      )

    id
  end

  defp attempt!(destination, fields) do
    %Attempt{}
    |> Attempt.changeset(
      Map.merge(
        %{
          destination_id: destination.id,
          batch_id: Ecto.UUID.generate(),
          started_at: DateTime.utc_now(),
          outcome: :rejected,
          event_count: 2,
          bytes: 2048,
          http_status: 400,
          error: "Rejected by the destination (HTTP 400)"
        },
        fields
      )
    )
    |> Repo.insert!()
  end

  # A batch of two events, rejected three times, with a third event after
  # it, as Kanban.AuditStream.StatusTest builds it.
  defp reject_batch!(org, destination, error \\ "Rejected by the destination (HTTP 400)") do
    first = event!(org, 5, ~N[2026-11-01 00:00:00.000000])
    last = event!(org, 6, ~N[2026-11-01 00:05:00.000000])
    event!(org, 7, ~N[2026-11-01 00:10:00.000000])
    batch_id = Ecto.UUID.generate()

    set_cursor(destination,
      last_txid: 4,
      last_event_id: 0,
      pending_batch_id: batch_id,
      pending_first_txid: 5,
      pending_first_id: first,
      pending_last_txid: 6,
      pending_last_id: last,
      pending_attempts: 3,
      pending_filter_version: 1
    )

    set(destination, state: :failing, state_reason: error, halted_reason: :rejected_batch)
    attempt!(destination, %{batch_id: batch_id, error: error})
    %{batch_id: batch_id, first: first, last: last}
  end

  defp events(org, action) do
    from(e in AuditEvent, where: e.organization_id == ^org.id and e.action == ^action)
    |> Repo.all()
  end

  defp jobs(destination),
    do: all_enqueued(worker: DispatchWorker, args: %{destination_id: destination.id})

  # --- access -------------------------------------------------------------------

  describe "access" do
    test "another Organization's destination id redirects as not found", %{conn: conn} do
      other = organization_fixture() |> destination_fixture(:https)

      for target <- [
            path(other),
            ~p"/org/audit/streaming/0",
            ~p"/org/audit/streaming/-1",
            ~p"/org/audit/streaming/abc",
            ~p"/org/audit/streaming/9223372036854775808"
          ] do
        assert {:error, {:live_redirect, %{to: "/org/audit/streaming", flash: flash}}} =
                 live(conn, target)

        assert flash["error"] == @not_found
      end
    end

    test "a member who is not an org-admin is refused", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      member = user_fixture()
      organization_member_fixture(org, member, :member)

      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               conn |> log_in_user(member) |> live(path(destination))
    end
  end

  # --- what the page shows ------------------------------------------------------

  describe "the page" do
    test "an org-admin sees settings, status, lag, gaps and the last 50 attempts",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec, %{settings: %{"index" => "security"}})
      gap_fixture(destination)
      gap_fixture(destination, %{reason: :too_old, events: 1, dismissed_at: DateTime.utc_now()})

      for n <- 1..55,
          do:
            attempt!(destination, %{
              outcome: :delivered,
              http_status: 200,
              error: nil,
              event_count: n
            })

      {:ok, lv, html} = live(conn, path(destination))

      assert html =~ destination.name
      assert has_element?(lv, "#destination-status[data-status-pill=healthy]", "Healthy")
      assert has_element?(lv, "#destination-host", "collector.example.com")
      assert has_element?(lv, "#destination-hint", "•••• ")
      assert has_element?(lv, "[data-setting]", "security")
      assert has_element?(lv, "#destination-lag", "Up to date")
      assert has_element?(lv, "#destination-last-delivered", "Never")

      assert lv |> element("#gap-rows") |> render() =~ "12 events lost"
      assert has_element?(lv, "li[data-dismissed=true]", "1 event lost")
      assert has_element?(lv, "li[data-dismissed=true]", "Too old for Datadog")
      assert has_element?(lv, "li[data-dismissed=false]", "Deleted by retention")

      rows = lv |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#attempt-rows tr")
      assert Enum.count(rows) == 50
      assert has_element?(lv, "#attempt-rows [data-outcome=delivered]", "Delivered")
      assert has_element?(lv, "#attempt-rows", "2 KB")
      refute has_element?(lv, "#destination-signing-secret")
      refute has_element?(lv, "#destination-rejected-batch")
    end

    test "a stored over-long service or source type still renders whole in the settings rows (D447)",
         %{conn: conn, org: org} do
      for {kind, key} <- [datadog: "service", splunk_hec: "source_type"] do
        long = String.duplicate("監", 150)
        destination = destination_fixture(org, kind)
        destination = set(destination, settings: Map.put(destination.settings, key, long))

        {:ok, lv, _html} = live(conn, path(destination))
        assert has_element?(lv, "[data-setting]", long), "#{kind}"
        refute render(lv) =~ "At most 100 characters."
      end
    end

    test "a destination with no attempts and no gaps shows the empty states",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :datadog)
      {:ok, lv, _html} = live(conn, path(destination))

      assert has_element?(lv, "#attempts-empty", "No attempts yet.")
      assert has_element?(lv, "#gaps-empty")
      refute has_element?(lv, "#attempt-rows")
      refute has_element?(lv, "#rejected-batch-answer")
    end

    test "attempt errors are escaped and no secret appears in the HTML", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      attempt!(destination, %{error: "<script>alert('x')</script> & more"})

      {:ok, lv, html} = live(conn, path(destination))

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>alert"
      assert has_element?(lv, "[data-attempt-error]", "<script>alert('x')</script> & more")

      stored = Repo.get!(Destination, destination.id)
      refute html =~ stored.url
      refute html =~ "path-token"
      refute html =~ "assec_"
    end

    test "an HTTPS destination shows its format by name and its authorization header name",
         %{conn: conn, org: org} do
      destination =
        destination_fixture(org, :https, %{
          credential: "Bearer page-credential-9z8y",
          settings: %{"format" => "ndjson", "header_name" => "Authorization"}
        })

      {:ok, lv, html} = live(conn, path(destination))

      settings =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("dl div:has(dd[data-setting])")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
        |> Enum.map(&String.trim/1)

      assert "Format NDJSON" in settings
      assert "Authorization header name Authorization" in settings
      refute html =~ "Signature header"
      refute has_element?(lv, "dd[data-setting]", "ndjson")
      refute html =~ "page-credential"
    end

    test "renders in every locale", %{conn: conn, org: org} do
      destination =
        destination_fixture(org, :https, %{
          credential: "Bearer locale-credential-4321",
          settings: %{"format" => "json", "header_name" => "Authorization"}
        })

      reject_batch!(org, destination)

      for locale <- ~w(de en es fr ja pt zh) do
        {:ok, lv, _html} =
          conn
          |> Plug.Test.init_test_session(%{"locale" => locale})
          |> live(path(destination))

        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          retry = Gettext.gettext(KanbanWeb.Gettext, "Retry now")
          skip = Gettext.gettext(KanbanWeb.Gettext, "Skip this batch")
          rotate = Gettext.gettext(KanbanWeb.Gettext, "Rotate signing secret")

          confirmation =
            Gettext.dngettext(
              KanbanWeb.Gettext,
              "default",
              "This event will not be sent to this destination. It stays in the audit log and in exports.",
              "These %{count} events will not be sent to this destination. They stay in the audit log and in exports.",
              2,
              %{}
            )

          assert has_element?(lv, "#retry-now", retry)
          assert has_element?(lv, "#skip-batch", skip)
          assert has_element?(lv, "#rotate-secret", rotate)

          header_label = Gettext.gettext(KanbanWeb.Gettext, "Authorization header name")
          json_batch = Gettext.gettext(KanbanWeb.Gettext, "JSON batch")
          assert has_element?(lv, "dt", header_label)
          assert has_element?(lv, "dd[data-setting]", json_batch)

          [attr] =
            lv
            |> render()
            |> LazyHTML.from_fragment()
            |> LazyHTML.query("#skip-batch")
            |> LazyHTML.attribute("data-confirm")

          assert attr == confirmation

          if locale != "en" do
            refute retry == "Retry now", "#{locale} lacks Retry now"
            refute skip == "Skip this batch", "#{locale} lacks Skip this batch"
            refute confirmation =~ "will not be sent", "#{locale} lacks the skip plural"
            refute header_label == "Authorization header name", "#{locale} lacks the header label"
            refute json_batch == "JSON batch", "#{locale} lacks JSON batch"
          end
        end)
      end
    end
  end

  # --- halted reasons -----------------------------------------------------------

  describe "halted destinations" do
    test "a rejected batch offers Retry now and Skip this batch with the confirmation",
         %{conn: conn, org: org, org_admin: org_admin} do
      destination = destination_fixture(org, :https)
      batch = reject_batch!(org, destination)

      {:ok, lv, _html} = live(conn, path(destination))

      assert has_element?(lv, "#destination-reason[data-halted-reason=rejected_batch]")
      assert has_element?(lv, "#rejected-batch-answer", "Rejected by the destination (HTTP 400)")
      assert has_element?(lv, "#rejected-batch-events", "2")
      assert has_element?(lv, "#rejected-batch-first", "November 1, 2026 at 12:00 AM")
      assert has_element?(lv, "#rejected-batch-last", "November 1, 2026 at 12:05 AM")
      assert has_element?(lv, "#retry-now")

      assert has_element?(
               lv,
               ~s(#skip-batch[data-confirm="These 2 events will not be sent to this destination. They stay in the audit log and in exports."])
             )

      refute has_element?(lv, "#rejected-batch-partial-note")

      lv |> element("#skip-batch") |> render_click()

      assert render(lv) =~ "Batch skipped."
      assert Repo.get!(Destination, destination.id).halted_reason == nil
      refute has_element?(lv, "#skip-batch")
      assert {cursor(destination).last_txid, cursor(destination).last_event_id} == {6, batch.last}

      skipped =
        from(a in Attempt,
          where: a.destination_id == ^destination.id and a.outcome == :skipped
        )

      assert [%Attempt{event_count: 2}] = Repo.all(skipped)

      assert [event] = events(org, "audit_stream_batch_skipped")
      assert event.metadata["user_id"] == org_admin.id
      assert event.metadata["events"] == 2
    end

    test "Retry now clears the halt and enqueues the dispatch job", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      reject_batch!(org, destination)

      {:ok, lv, _html} = live(conn, path(destination))
      lv |> element("#retry-now") |> render_click()

      assert render(lv) =~ "Retrying the batch now."
      assert Repo.get!(Destination, destination.id).halted_reason == nil
      assert [_job] = jobs(destination)
      assert events(org, "audit_stream_batch_skipped") == []
      refute has_element?(lv, "#retry-now")
    end

    test "a Splunk invalid-event-number above 0 adds the already-in-Splunk note",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec)

      batch =
        reject_batch!(
          org,
          destination,
          "Splunk HEC answered HTTP 400 with code 6, invalid-event-number 3; the events before it may already be indexed"
        )

      {:ok, lv, _html} = live(conn, path(destination))
      assert has_element?(lv, "#rejected-batch-partial-note", "may already be in Splunk")

      # The same pending batch, rejected at event 0: the batch card shows,
      # so the missing note is the invalid-event-number check, not a
      # missing batch.
      other = destination_fixture(org, :splunk_hec)
      zero = "Splunk HEC answered HTTP 400 with code 6, invalid-event-number 0"
      other_batch_id = Ecto.UUID.generate()

      set_cursor(other,
        last_txid: 4,
        last_event_id: 0,
        pending_batch_id: other_batch_id,
        pending_first_txid: 5,
        pending_first_id: batch.first,
        pending_last_txid: 6,
        pending_last_id: batch.last,
        pending_attempts: 3,
        pending_filter_version: 1
      )

      set(other, state: :failing, halted_reason: :rejected_batch, state_reason: zero)
      attempt!(other, %{batch_id: other_batch_id, error: zero})

      {:ok, lv, _html} = live(conn, path(other))
      assert has_element?(lv, "#rejected-batch-events")
      refute has_element?(lv, "#rejected-batch-partial-note")
    end

    test "a config error shows its fix and no Skip this batch", %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec, %{settings: %{"index" => "main"}})

      error =
        "Splunk HEC answered HTTP 400 with code 7 (the token can't write to the index)"

      set(destination, state: :failing, state_reason: error)
      attempt!(destination, %{outcome: :config_error, error: error})

      {:ok, lv, _html} = live(conn, path(destination))

      assert has_element?(
               lv,
               "#destination-config-error-fix",
               "The token can't write to index main"
             )

      refute has_element?(lv, "#skip-batch")
      refute has_element?(lv, "#retry-now")
    end

    test "blocked_address and txid_reset offer neither button; txid_reset shows the re-seed reason",
         %{conn: conn, org: org} do
      for reason <- [:blocked_address, :txid_reset] do
        destination = destination_fixture(org, :https)
        reject_batch!(org, destination)
        set(destination, halted_reason: reason)

        {:ok, lv, _html} = live(conn, path(destination))

        assert has_element?(lv, "#destination-reason[data-halted-reason=#{reason}]")
        refute has_element?(lv, "#skip-batch")
        refute has_element?(lv, "#retry-now")

        if reason == :txid_reset do
          assert has_element?(
                   lv,
                   "#destination-reason",
                   "The database was moved. An operator must re-seed audit streaming."
                 )
        end
      end
    end

    test "credentials_unreadable shows the edit link and no Retry now or Skip this batch",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec)
      reject_batch!(org, destination)
      set(destination, halted_reason: :credentials_unreadable)

      {:ok, lv, _html} = live(conn, path(destination))

      assert has_element?(
               lv,
               "#destination-reason",
               "Credentials can't be read. Enter them again."
             )

      assert has_element?(
               lv,
               ~s(#destination-edit-link[href="/org/audit/streaming/#{destination.id}/edit"])
             )

      refute has_element?(lv, "#retry-now")
      refute has_element?(lv, "#skip-batch")
    end

    test "a crafted skip_batch or retry_now event on a healthy destination changes nothing",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      before = cursor(destination)

      {:ok, lv, _html} = live(conn, path(destination))

      for event <- ["skip_batch", "retry_now"] do
        assert render_click(lv, event, %{}) =~
                 "This destination is no longer waiting on a rejected batch."
      end

      assert cursor(destination) == before
      assert events(org, "audit_stream_batch_skipped") == []
      assert jobs(destination) == []
    end
  end

  # --- gaps ---------------------------------------------------------------------

  describe "gaps" do
    test "dismiss a gap records audit_stream_gap_dismissed and clears the list warning",
         %{conn: conn, org: org, org_admin: org_admin} do
      destination = destination_fixture(org, :https)
      gap = gap_fixture(destination)

      {:ok, list, _html} = live(conn, ~p"/org/audit/streaming")
      assert has_element?(list, "#destination-gap-warning-#{destination.id}", "12 events")

      {:ok, lv, _html} = live(conn, path(destination))
      lv |> element("#dismiss-gap-#{gap.id}") |> render_click()

      assert render(lv) =~ "Gap dismissed."
      assert has_element?(lv, "#gap-#{gap.id}[data-dismissed=true]")
      refute has_element?(lv, "#dismiss-gap-#{gap.id}")
      assert Repo.get!(Gap, gap.id).dismissed_by_id == org_admin.id

      assert [event] = events(org, "audit_stream_gap_dismissed")

      assert event.metadata == %{
               "user_id" => org_admin.id,
               "organization_id" => org.id,
               "destination_id" => destination.id,
               "gap_id" => gap.id
             }

      {:ok, list, _html} = live(conn, ~p"/org/audit/streaming")
      refute has_element?(list, "#destination-gap-warning-#{destination.id}")
    end

    test "a gap of another destination is not dismissed from this page", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      other_gap = org |> destination_fixture(:https) |> gap_fixture()

      {:ok, lv, _html} = live(conn, path(destination))
      render_click(lv, "dismiss_gap", %{"id" => to_string(other_gap.id)})

      assert Repo.get!(Gap, other_gap.id).dismissed_at == nil
      assert events(org, "audit_stream_gap_dismissed") == []
    end

    test "a crafted dismiss_gap event with a non-string id changes nothing",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      gap = gap_fixture(destination)
      {:ok, lv, _html} = live(conn, path(destination))

      for id <- [%{"id" => gap.id}, [gap.id], gap.id] do
        render_click(lv, "dismiss_gap", %{"id" => id})
      end

      assert has_element?(lv, "#gap-#{gap.id}[data-dismissed=false]")
      assert Repo.get!(Gap, gap.id).dismissed_at == nil
    end
  end

  # --- signing secret -----------------------------------------------------------

  describe "signing secret" do
    test "rotate signing secret shows the new secret once", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, path(destination))

      lv |> element("#rotate-secret") |> render_click()

      secret = lv |> element("#destination-secret-value") |> render()
      assert secret =~ "assec_"
      assert has_element?(lv, "#destination-secret-overlap", "The old secret stays valid until")
      assert has_element?(lv, "#rotate-again-note")

      # A second rotation inside the 24 hours is refused, and the secret shown
      # once is gone.
      lv |> element("#rotate-secret") |> render_click()
      assert render(lv) =~ "You can rotate the signing secret again after"
      refute has_element?(lv, "#destination-secret-value")

      {:ok, lv, _html} = live(conn, path(destination))
      refute has_element?(lv, "#destination-secret-reveal")
    end

    test "Dismiss hides the revealed secret", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, path(destination))

      lv |> element("#rotate-secret") |> render_click()
      assert has_element?(lv, "#destination-secret-value")

      lv |> element("#destination-secret-dismiss") |> render_click()
      refute has_element?(lv, "#destination-secret-reveal")
    end

    test "an unreadable signing secret says there is no 24-hour overlap", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      make_unreadable!(destination, :signing_secret)

      {:ok, lv, _html} = live(conn, path(destination))
      assert has_element?(lv, "#rotate-no-overlap-note", "no 24-hour overlap")

      lv |> element("#rotate-secret") |> render_click()
      assert has_element?(lv, "#destination-secret-value")
      refute has_element?(lv, "#destination-secret-overlap")
      refute has_element?(lv, "#rotate-no-overlap-note")
    end

    test "Rotate signing secret on a Splunk destination is refused", %{conn: conn, org: org} do
      destination = destination_fixture(org, :splunk_hec)
      {:ok, lv, _html} = live(conn, path(destination))

      refute has_element?(lv, "#rotate-secret")

      assert render_click(lv, "rotate_secret", %{}) =~
               "Only HTTPS endpoints have a signing secret."

      refute has_element?(lv, "#destination-secret-reveal")
    end
  end

  # --- changing rights and races ------------------------------------------------

  describe "rights and races" do
    test "an org-admin demoted while the page is open is refused on skip and nothing changes",
         %{conn: conn, org: org, org_admin: org_admin} do
      destination = destination_fixture(org, :https)
      gap = gap_fixture(destination)
      reject_batch!(org, destination)

      for event <- ["skip_batch", "retry_now", "rotate_secret", "dismiss_gap"] do
        {:ok, lv, _html} = live(conn, path(destination))
        demote(org_admin)

        assert {:error, {:redirect, %{to: "/boards"}}} =
                 render_click(lv, event, %{"id" => to_string(gap.id)})

        from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :org_admin])
      end

      stored = Repo.get!(Destination, destination.id)
      assert stored.halted_reason == :rejected_batch
      assert stored.previous_secret_expires_at == nil
      assert Repo.get!(Gap, gap.id).dismissed_at == nil
      assert events(org, "audit_stream_batch_skipped") == []

      denied =
        from(e in AuditEvent,
          where: e.action == "permission_denied" and e.actor_user_id == ^org_admin.id
        )
        |> Repo.all()

      assert length(denied) == 4
      assert jobs(destination) == []
    end

    test "two org-admins clicking Skip this batch skip it once", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      reject_batch!(org, destination)
      other_admin = user_fixture()
      organization_member_fixture(org, other_admin, :org_admin)

      {:ok, lv1, _html} = live(conn, path(destination))
      {:ok, lv2, _html} = conn |> log_in_user(other_admin) |> live(path(destination))

      lv1 |> element("#skip-batch") |> render_click()

      assert lv2 |> element("#skip-batch") |> render_click() =~
               "This destination is no longer waiting on a rejected batch."

      assert length(events(org, "audit_stream_batch_skipped")) == 1
    end

    test "a destination deleted while its page is open redirects to the list",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      reject_batch!(org, destination)
      {:ok, lv, _html} = live(conn, path(destination))

      Destination |> Repo.get!(destination.id) |> Repo.delete!()

      lv |> element("#retry-now") |> render_click()
      flash = assert_redirect(lv, "/org/audit/streaming")
      assert flash["error"] == "That destination no longer exists."
    end
  end
end
