defmodule KanbanWeb.OrgLive.AuditStreamFormTest do
  @moduledoc """
  The org-admin add and edit destination form at `/org/audit/streaming/new`
  and `/org/audit/streaming/:id/edit` (W2717). Test events go to a `Req.Test`
  stub on `Kanban.Webhooks.Transport` and hosts resolve through the fixed
  DNS table of `Kanban.AuditStreamFixtures`. The configured maximum changes a
  global setting, so the limit is tested in
  `KanbanWeb.OrgLive.AuditStreamFormGlobalTest` below.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditStream.Adapters.Datadog
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport
  alias Kanban.Webhooks.UrlGuard
  alias KanbanWeb.OrgLive.AuditStreamForm
  alias KanbanWeb.OrgLive.AuditStreamFormView
  alias KanbanWeb.OrgLive.AuditStreamKinds

  @refusal "You must be an org-admin of an Organization to access this page."
  @body "port 22 open on 10.0.0.5"

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)
    stub(200)

    %{conn: log_in_user(conn, org_admin), org: org, org_admin: org_admin}
  end

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  defp stub(status), do: Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, status, @body))

  defp destinations(org),
    do: from(d in Destination, where: d.organization_id == ^org.id, order_by: d.id) |> Repo.all()

  defp edit_path(destination), do: ~p"/org/audit/streaming/#{destination.id}/edit"

  defp submit(lv, params),
    do: lv |> element("#destination-form") |> render_submit(%{"destination" => nest(params)})

  defp change(lv, params),
    do: lv |> element("#destination-form") |> render_change(%{"destination" => nest(params)})

  # The form sends its secrets under destination[secret_token], as the
  # inputs are named.
  defp nest(params) do
    case Map.take(params, ["url", "credential"]) do
      secrets when map_size(secrets) == 0 -> params
      secrets -> params |> Map.drop(["url", "credential"]) |> Map.put("secret_token", secrets)
    end
  end

  @splunk %{
    "kind" => "splunk_hec",
    "name" => "Splunk prod",
    "url" => "https://collector.example.com/services/collector/event",
    "credential" => "splunk-token-0123456789-abcd",
    "settings" => %{"index" => "main", "source_type" => ""},
    "start_from" => "now"
  }

  @datadog %{
    "kind" => "datadog",
    "name" => "Datadog EU",
    "credential" => "datadog-key-0123456789-wxyz",
    "settings" => %{"site" => "datadoghq.eu", "service" => "", "tags" => "env:prod team:sec"},
    "start_from" => "17h"
  }

  @https %{
    "kind" => "https",
    "name" => "SIEM",
    "url" => "https://siem.example.org/ingest/token-0123456789",
    "credential" => "Bearer abc-0123456789-qrst",
    "settings" => %{"format" => "json", "header_name" => "Authorization"},
    "start_from" => "now"
  }

  describe "AuditStreamKinds" do
    test "AuditStreamKinds lists the nine Datadog sites and the start points per type" do
      assert Enum.map(AuditStreamKinds.datadog_site_options(), &elem(&1, 1)) == [
               "datadoghq.com",
               "us3.datadoghq.com",
               "us5.datadoghq.com",
               "datadoghq.eu",
               "ap1.datadoghq.com",
               "ap2.datadoghq.com",
               "uk1.datadoghq.com",
               "ddog-gov.com",
               "us2.ddog-gov.com"
             ]

      assert length(Datadog.sites()) == 9

      starts = fn kind ->
        kind |> AuditStreamKinds.start_point_options() |> Enum.map(&elem(&1, 1))
      end

      assert starts.(:splunk_hec) == ~w(now 24h 7d all)
      assert starts.(:https) == ~w(now 24h 7d all)
      assert starts.(:datadog) == ~w(now 17h)

      assert AuditStreamKinds.normalize_start(:datadog, "7d") == "now"
      assert AuditStreamKinds.normalize_start(:datadog, "17h") == "17h"
      refute AuditStreamKinds.catch_up?("now")
      assert AuditStreamKinds.catch_up?("all")
    end

    test "kinds parse only from known names and no audit_stream_* action is offered" do
      assert AuditStreamKinds.parse_kind("datadog") == :datadog
      assert AuditStreamKinds.parse_kind(:https) == :https
      assert AuditStreamKinds.parse_kind("bogus") == nil
      assert AuditStreamKinds.parse_kind(:bogus) == nil
      assert AuditStreamKinds.parse_kind(nil) == nil
      assert AuditStreamKinds.secret_fields(:datadog) == [:credential]
      assert AuditStreamKinds.settings_keys(:https) == ~w(format header_name)
      assert AuditStreamKinds.url_warning(:https, "https://x.splunkcloud.com/a") == nil

      assert AuditStreamKinds.url_warning(:splunk_hec, "https://acme.splunkcloud.com/x") =~
               "http-inputs"

      actions = Enum.map(AuditStreamKinds.excludable_options(), &elem(&1, 1))
      assert actions != []
      refute Enum.any?(actions, &String.starts_with?(&1, "audit_stream_"))
    end
  end

  describe "AuditStreamFormView" do
    test "lift_secrets takes the secrets only from the filtered key" do
      assert AuditStreamFormView.lift_secrets(%{
               "name" => "n",
               "url" => "https://top.example.com",
               "secret_token" => %{
                 "url" => "https://x.example.com",
                 "credential" => "c",
                 "x" => "y"
               }
             }) == %{"name" => "n", "url" => "https://x.example.com", "credential" => "c"}

      assert AuditStreamFormView.lift_secrets(%{"credential" => "c", "secret_token" => "bad"}) ==
               %{}

      assert AuditStreamFormView.secret_input_name(:url) == "destination[secret_token][url]"
    end

    test "present translates a UrlGuard reason and settings never cut the tag text" do
      assert {:url, text} =
               AuditStreamFormView.present({:url, {"x", [reason: :blocked_address]}})

      assert text ==
               Gettext.dgettext(
                 KanbanWeb.Gettext,
                 "errors",
                 UrlGuard.error_message(:blocked_address)
               )

      tags = Enum.map(1..90, &(String.duplicate("t", 199) <> "#{rem(&1, 10)}"))

      assert AuditStreamFormView.settings(%{"tags" => Enum.join(tags, ", ")}, :datadog) == %{
               "tags" => tags
             }
    end

    test "attrs keep a blank secret out, split tags, take only the kind's settings and pass an unoffered start point on" do
      params = %{
        "name" => "D",
        "url" => "  ",
        "credential" => "",
        "settings" => %{"site" => "datadoghq.eu", "tags" => "a:b, c:d\ne:f", "index" => "x"},
        "excluded_actions" => ["", "sso_login"],
        "start_from" => "7d",
        "kind" => "datadog"
      }

      assert AuditStreamFormView.attrs(params, :new, :datadog) == %{
               "name" => "D",
               "kind" => "datadog",
               "start_from" => "7d",
               "settings" => %{"site" => "datadoghq.eu", "tags" => ["a:b", "c:d", "e:f"]},
               "excluded_actions" => ["sso_login"]
             }

      edit = params |> Map.put("url", "https://x") |> AuditStreamFormView.attrs(:edit, :https)
      refute Map.has_key?(edit, "kind")
      refute Map.has_key?(edit, "start_from")
      assert edit["url"] == "https://x"
      assert edit["settings"] == %{}
      assert AuditStreamFormView.settings(nil, :https) == %{}

      assert AuditStreamFormView.attrs(%{"name" => "D"}, :new, :splunk_hec)
             |> Map.take(["start_from", "settings"]) == %{
               "start_from" => "now",
               "settings" => %{}
             }

      refute %{"name" => "D"}
             |> AuditStreamFormView.attrs(:edit, :splunk_hec)
             |> Map.has_key?("settings")

      assert AuditStreamFormView.settings(%{"index" => 7, "source_type" => " "}, :splunk_hec) ==
               %{"index" => 7}
    end

    test "filters, the personal-data confirmation and hints" do
      values = %{include_personal_data: false, excluded_actions: ["b", "a"]}
      assert AuditStreamFormView.filters(values) == {false, ["a", "b"]}
      assert AuditStreamFormView.personal_data_off?(values, nil)
      assert AuditStreamFormView.personal_data_off?(values, {true, []})
      refute AuditStreamFormView.personal_data_off?(values, {false, []})
      refute AuditStreamFormView.personal_data_off?(%{include_personal_data: true}, nil)
      refute AuditStreamFormView.filters_changed?(values, nil)
      assert AuditStreamFormView.filters_changed?(values, {true, []})

      assert AuditStreamFormView.hints(%Destination{url_hint: "abcd", credential_hint: nil}) ==
               %{url: "•••• abcd", credential: "••••"}

      assert AuditStreamFormView.secret_states(%Destination{url: :unreadable, credential: "x"}) ==
               %{url: :unreadable, credential: :stored}
    end

    test "every error class becomes translated text on its own input" do
      present = &AuditStreamFormView.present/1
      assert {:index, _} = present.({:settings, {"is invalid", validation: :index}})
      assert {:format, _} = present.({:settings, {"is invalid", validation: :format}})
      assert {:header_name, _} = present.({:settings, {"is invalid", validation: :header_name}})
      assert {:settings, _} = present.({:settings, {"is invalid", validation: :settings}})

      assert {:credential, "Enter the header name for this value."} =
               present.({:settings, {"is invalid", validation: :header_name_required}})

      assert {:url, "Can't be read. Enter it again."} =
               present.({:url, {"can't be blank", validation: :unreadable}})

      assert {:url, "Enter a valid https:// address."} =
               present.({:url, {"is invalid", validation: :url}})

      assert {:url, "must start with https://"} =
               present.({:url, {"is invalid", validation: :scheme_not_allowed}})

      assert {:url, "points to a private or reserved network address"} =
               present.(
                 {:url,
                  {"points to a private or reserved network address", reason: :blocked_address}}
               )

      assert {:credential, _} = present.({:credential, {"is invalid", validation: :header_value}})
      assert {:credential, _} = present.({:credential, {"can't be blank", validation: :required}})

      assert {:excluded_actions, "Choose actions from the list."} =
               present.({:excluded_actions, {"has an invalid entry", validation: :subset}})

      assert {:start_from, _} = present.({:start_from, {"is invalid", validation: :inclusion}})
      assert {:kind, _} = present.({:kind, {"is invalid", validation: :inclusion}})

      assert {:name, "can't be blank"} =
               present.({:name, {"can't be blank", validation: :required}})
    end
  end

  describe "creating" do
    test "creates a Splunk, a Datadog and an HTTPS destination and shows the test result",
         %{conn: conn, org: org} do
      stub(200)

      for params <- [@splunk, @datadog, @https] do
        {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
        change(lv, %{"kind" => params["kind"]})
        submit(lv, params)

        destination = org |> destinations() |> List.last()
        assert destination.name == params["name"]
        assert destination.kind == String.to_existing_atom(params["kind"])
        assert_patch(lv, edit_path(destination))

        render_async(lv, 5_000)

        assert has_element?(
                 lv,
                 "#destination-form-test-result[data-test-result=ok]",
                 "Test event delivered"
               )
      end

      assert [splunk, datadog, https] = destinations(org)
      assert splunk.settings == %{"index" => "main"}
      assert datadog.settings == %{"site" => "datadoghq.eu", "tags" => ["env:prod", "team:sec"]}
      assert https.settings == %{"format" => "json", "header_name" => "Authorization"}
      assert Repo.get!(Cursor, datadog.id).not_before
    end

    test "changing Type swaps the fields; Datadog offers only the nine sites and two starts",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")

      assert has_element?(lv, "#destination_url_splunk_hec")
      assert has_element?(lv, "#destination-form-ack-note")
      refute has_element?(lv, "#destination_settings_site")

      change(lv, %{"kind" => "datadog", "start_from" => "7d"})
      refute has_element?(lv, "#destination_url_datadog")
      assert has_element?(lv, "#destination_credential_datadog")

      sites =
        for site <- Datadog.sites(), do: ~s(#destination_settings_site option[value="#{site}"])

      assert Enum.all?(sites, &has_element?(lv, &1))

      site_select = lv |> element("#destination_settings_site") |> render()
      assert length(Regex.scan(~r/<option /, site_select)) == 9

      assert has_element?(lv, ~s(#destination_start_from option[value="now"]))
      assert has_element?(lv, ~s(#destination_start_from option[value="17h"]))
      refute has_element?(lv, ~s(#destination_start_from option[value="7d"]))
      refute has_element?(lv, ~s(#destination_start_from option[value="all"]))

      change(lv, %{"kind" => "https"})
      assert has_element?(lv, "#destination_settings_format")
      assert has_element?(lv, "#destination_settings_header_name")
    end

    test "Start from shows only on create and a catch-up says every org-admin will be told",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      assert has_element?(lv, "#destination_start_from")
      refute has_element?(lv, "#destination-form-catch-up-note")

      change(lv, %{"start_from" => "all"})
      assert has_element?(lv, "#destination-form-catch-up-note", "every org-admin")

      {:ok, lv, _html} = live(conn, edit_path(destination_fixture(org, :https)))
      refute has_element?(lv, "#destination_start_from")
      refute has_element?(lv, "#destination_kind")
      assert has_element?(lv, "#destination-form-kind[data-kind=https]")
    end

    test "saves even when the test event fails and shows only the coarse class",
         %{conn: conn, org: org} do
      stub(500)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      submit(lv, @splunk)
      render_async(lv, 5_000)

      html = render(lv)
      assert has_element?(lv, "#destination-form-test-result[data-test-result=error]", "(500)")
      refute html =~ @body
      assert [_saved] = destinations(org)

      Req.Test.stub(Transport, &Req.Test.transport_error(&1, :econnrefused))
      [destination] = destinations(org)
      {:ok, lv, _html} = live(conn, edit_path(destination))
      submit(lv, %{"name" => "Renamed"})
      render_async(lv, 5_000)
      assert has_element?(lv, "#destination-form-test-result", "Could not connect")
      assert Repo.get!(Destination, destination.id).name == "Renamed"
    end

    test "shows the HTTPS signing secret once and not after reload", %{conn: conn, org: org} do
      stub(200)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, @https)

      [destination] = destinations(org)
      secret = destination.signing_secret
      assert has_element?(lv, "#form-secret-value", secret)
      assert has_element?(lv, "#form-secret-copy")
      assert has_element?(lv, "#form-secret-reveal", "won't be able to see it again")

      lv |> element("#form-secret-dismiss") |> render_click()
      refute has_element?(lv, "#form-secret-reveal")

      {:ok, _lv, html} = live(conn, edit_path(destination))
      refute html =~ secret
    end

    test "shows field errors for a bad Splunk path, a reserved header name in mixed case, too many tags and a duplicate name",
         %{conn: conn, org: org} do
      taken = destination_fixture(org, :datadog)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")

      html = change(lv, %{"url" => "https://collector.example.com/services/collector/raw"})
      assert html =~ "Use the collector path"

      html = change(lv, %{"url" => "https://acme.splunkcloud.com/services/collector"})
      assert has_element?(lv, "#destination-form-url-warning", "http-inputs")
      refute html =~ "Use the collector path"

      change(lv, %{"kind" => "https"})
      html = change(lv, %{"kind" => "https", "settings" => %{"header_name" => "X-Stride-Batch"}})
      assert html =~ "Stride sets this header itself"

      change(lv, %{"kind" => "datadog"})
      tags = Enum.map_join(1..91, " ", &"k:#{&1}")
      html = change(lv, %{"kind" => "datadog", "settings" => %{"tags" => tags}})
      assert html =~ "Use at most 90 tags"

      html = submit(lv, Map.put(@datadog, "name", taken.name))
      assert html =~ "has already been taken"

      html =
        submit(
          lv,
          Map.merge(@splunk, %{"url" => "https://internal.example.com/services/collector"})
        )

      assert html =~ "points to a private or reserved network address"
      assert destinations(org) == [taken]

      stub(500)
      submit(lv, @splunk)
      render_async(lv, 5_000)
      assert has_element?(lv, "#destination-form-test-result[data-test-result=error]", "(500)")
      assert length(destinations(org)) == 2
    end

    # The fixture resolver raises for raise.example.com and exits for
    # exit.example.com, inside the UrlGuard check the save runs.
    test "a raise in save is contained, reported without its params and never logs the typed secrets",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      secret = "splunk-token-raise-0123456789"
      url = "https://raise.example.com/services/collector/event"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = submit(lv, Map.merge(@splunk, %{"url" => url, "credential" => secret}))
          assert html =~ "Something went wrong"
        end)

      assert Process.alive?(lv.pid)
      assert log =~ "Audit stream form save failed: RuntimeError"
      refute log =~ secret
      refute log =~ "resolver failed"
      assert destinations(org) == []

      assert [%ErrorTracker.Error{reason: "Audit stream form save failed: RuntimeError"}] =
               Repo.all(ErrorTracker.Error)

      stored = inspect(Repo.all(ErrorTracker.Occurrence))
      refute stored =~ secret
      refute stored =~ "raise.example.com"
    end

    test "an exit in save is contained and never logs the typed secrets", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      secret = "splunk-token-exit-0123456789"
      url = "https://exit.example.com/services/collector/event"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = submit(lv, Map.merge(@splunk, %{"url" => url, "credential" => secret}))
          assert html =~ "Something went wrong"
        end)

      assert Process.alive?(lv.pid)
      assert log =~ "Audit stream form save failed: :exit"
      refute log =~ secret
      refute log =~ "resolver_down"
    end

    # A kind the schema can't load makes every read of the row raise.
    test "a raise in validate is contained, clears the signing secret and never logs the typed secrets",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, @https)
      render_async(lv, 5_000)
      assert has_element?(lv, "#form-secret-reveal")

      [destination] = destinations(org)

      Repo.query!("UPDATE audit_stream_destinations SET kind = 'smtp' WHERE id = $1", [
        destination.id
      ])

      secret = "Bearer validate-raise-0123456789"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = change(lv, %{"name" => "Renamed", "credential" => secret})
          assert html =~ "Something went wrong"
        end)

      assert Process.alive?(lv.pid)
      refute has_element?(lv, "#form-secret-reveal")
      assert log =~ "Audit stream form validate failed: ArgumentError"
      refute log =~ secret
      refute log =~ "smtp"
    end

    test "the shown signing secret is not in the LiveView's inspected state", %{
      conn: conn,
      org: org
    } do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, @https)
      render_async(lv, 5_000)

      [destination] = destinations(org)
      assert has_element?(lv, "#form-secret-value", destination.signing_secret)
      refute inspect(:sys.get_state(lv.pid)) =~ destination.signing_secret

      refute inspect(%AuditStreamForm.ShownSecret{value: "shown-0123456789"}) =~
               "shown-0123456789"
    end

    test "a patch to /new or another destination drops the signing secret and test result",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, @https)
      render_async(lv, 5_000)
      assert has_element?(lv, "#form-secret-reveal")
      assert has_element?(lv, "#destination-form-test-result")

      render_patch(lv, ~p"/org/audit/streaming/new")
      refute has_element?(lv, "#form-secret-reveal")
      refute has_element?(lv, "#destination-form-test-result")

      other = destination_fixture(org, :datadog)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, Map.put(@https, "name", "Second"))
      render_async(lv, 5_000)
      assert has_element?(lv, "#form-secret-reveal")

      render_patch(lv, edit_path(other))
      refute has_element?(lv, "#form-secret-reveal")
      refute has_element?(lv, "#destination-form-test-result")
    end

    test "a patch while a test event is still running shows no result for it",
         %{conn: conn, org: org} do
      test_pid = self()

      Req.Test.stub(Transport, fn conn ->
        send(test_pid, {:blocked, self()})

        receive do
          :release -> Plug.Conn.send_resp(conn, 200, @body)
        end
      end)

      destination = destination_fixture(org, :splunk_hec)
      {:ok, lv, _html} = live(conn, edit_path(destination))
      submit(lv, %{"name" => "Renamed"})
      assert_receive {:blocked, post}, 5_000
      # The post runs under the LiveView's own test-event task, its caller.
      {:dictionary, dictionary} = Process.info(post, :dictionary)
      [task | _callers] = Keyword.fetch!(dictionary, :"$callers")
      ref = Process.monitor(task)

      render_patch(lv, ~p"/org/audit/streaming/new")
      assert_receive {:DOWN, ^ref, :process, ^task, {:shutdown, :cancel}}, 5_000

      refute render(lv) =~ "destination-form-test-result"
      refute has_element?(lv, "#destination-form-test-result")
      send(post, :release)
    end

    test "an unknown event clears a shown signing secret", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      change(lv, %{"kind" => "https"})
      submit(lv, @https)
      render_async(lv, 5_000)
      assert has_element?(lv, "#form-secret-reveal")

      render_hook(lv, "crafted_event", %{})
      refute has_element?(lv, "#form-secret-reveal")
    end

    test "an unoffered start point or a non-text setting is refused with a field error",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")

      html = render_submit(lv, "save", %{"destination" => Map.put(@datadog, "start_from", "all")})
      assert html =~ "Choose one of the listed start points."

      html =
        render_submit(lv, "save", %{
          "destination" => nest(Map.put(@splunk, "settings", %{"index" => ["main"]}))
        })

      assert html =~ "These settings don&#39;t belong to this type."

      for settings <- [
            %{"index" => %{"x" => "y"}},
            %{"source_type" => %{"x" => "y"}},
            %{"index" => [%{"x" => "y"}]}
          ] do
        params = nest(Map.put(@splunk, "settings", settings))
        assert render_change(lv, "validate", %{"destination" => params}) =~ "Splunk prod"
        html = render_submit(lv, "save", %{"destination" => params})
        assert html =~ "These settings don&#39;t belong to this type."
        refute html =~ @splunk["credential"]
      end

      html =
        render_submit(lv, "save", %{
          "destination" => Map.put(@datadog, "settings", %{"tags" => %{"x" => "y"}})
        })

      assert html =~ "These settings don&#39;t belong to this type."
      assert Process.alive?(lv.pid)
      assert destinations(org) == []
    end

    test "an unknown type shows only the type error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")

      html =
        render_submit(lv, "save", %{
          "destination" => nest(Map.put(@splunk, "kind", "bogus"))
        })

      assert html =~ "Choose a destination type."
      refute html =~ "These settings don&#39;t belong to this type."
    end

    test "an edit save that sends no settings keeps the stored ones", %{conn: conn, org: org} do
      destination =
        destination_fixture(org, :splunk_hec, %{
          settings: %{"index" => "security", "source_type" => "stride:audit"}
        })

      {:ok, lv, _html} = live(conn, edit_path(destination))
      render_submit(lv, "save", %{"destination" => %{"name" => "Renamed"}})
      render_async(lv, 5_000)

      fresh = Repo.get!(Destination, destination.id)
      assert fresh.name == "Renamed"
      assert fresh.settings == %{"index" => "security", "source_type" => "stride:audit"}
    end

    test "a crafted audit_stream_* excluded action is refused", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      refute render(lv) =~ ~s(value="audit_stream_)

      html =
        submit(lv, Map.put(@splunk, "excluded_actions", ["", "audit_stream_destination_deleted"]))

      assert html =~ "Changes to audit streaming can&#39;t be left out."
      assert destinations(org) == []
    end

    test "a crafted kind value is refused", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      html = submit(lv, Map.put(@splunk, "kind", "smtp"))
      assert html =~ "Choose a destination type."
      assert destinations(org) == []
    end

    test "turning Include email and IP addresses off asks for confirmation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      refute has_element?(lv, "#destination-form-save[data-confirm]")
      change(lv, %{"include_personal_data" => "false"})
      assert has_element?(lv, "#destination-form-save[data-confirm]")
      change(lv, %{"include_personal_data" => "true"})
      refute has_element?(lv, "#destination-form-save[data-confirm]")
    end
  end

  describe "editing" do
    test "edit keeps a blank secret and never renders a stored secret", %{conn: conn, org: org} do
      stub(200)

      for kind <- [:splunk_hec, :datadog, :https] do
        destination =
          destination_fixture(
            org,
            kind,
            if(kind == :https,
              do: %{
                credential: "Bearer stored-0123456789-zzzz",
                settings: %{"format" => "json", "header_name" => "Authorization"}
              },
              else: %{}
            )
          )

        secrets =
          [destination.url, destination.credential, destination.signing_secret]
          |> Enum.filter(&is_binary/1)

        {:ok, lv, dead} = live(conn, edit_path(destination))
        connected = render(lv)
        validated = change(lv, %{"name" => ""})
        failed = submit(lv, %{"name" => ""})

        for html <- [dead, connected, validated, failed], secret <- secrets do
          refute html =~ secret, "#{kind} rendered a stored secret"
        end

        assert has_element?(lv, "#destination-form-credential-hint", "•••• ")
        submit(lv, %{"name" => "Kept #{kind}"})
        render_async(lv, 5_000)

        fresh = Repo.get!(Destination, destination.id)
        assert fresh.name == "Kept #{kind}"
        assert fresh.url == destination.url
        assert fresh.credential == destination.credential

        lv |> element("#destination-form-credential-replace") |> render_click()
        submit(lv, %{"credential" => ""})
        render_async(lv, 5_000)
        assert Repo.get!(Destination, destination.id).credential == destination.credential

        lv |> element("#destination-form-credential-replace") |> render_click()
        submit(lv, %{"credential" => "replaced-0123456789-mnop"})
        render_async(lv, 5_000)
        assert Repo.get!(Destination, destination.id).credential_hint == "mnop"
      end
    end

    test "an unreadable credential renders as can't be read and blocks Save until replaced",
         %{conn: conn, org: org} do
      stub(200)
      destination = destination_fixture(org, :datadog)
      make_unreadable!(destination, :credential)
      {:ok, lv, _html} = live(conn, edit_path(destination))

      assert has_element?(
               lv,
               "#destination-form-credential-unreadable",
               "Can't be read. Enter it again."
             )

      assert has_element?(lv, ~s(#destination_credential_datadog[value=""]))

      html = submit(lv, %{"name" => "Still unreadable"})
      assert html =~ "Can&#39;t be read. Enter it again."
      assert Repo.get!(Destination, destination.id).lock_version == destination.lock_version

      submit(lv, %{"credential" => "new-datadog-key-0123456789"})
      assert Repo.get!(Destination, destination.id).credential == "new-datadog-key-0123456789"
      refute has_element?(lv, "#destination-form-credential-unreadable")
    end

    test "a filter change with a pending batch shows the re-send note", %{conn: conn, org: org} do
      stub(200)
      destination = destination_fixture(org, :https)

      from(c in Cursor, where: c.destination_id == ^destination.id)
      |> Repo.update_all(set: [pending_batch_id: Ecto.UUID.generate()])

      {:ok, lv, _html} = live(conn, edit_path(destination))
      refute has_element?(lv, "#destination-form-resend-note")

      change(lv, %{"excluded_actions" => ["", "sso_login"]})

      assert has_element?(
               lv,
               "#destination-form-resend-note",
               "sent again under the new settings"
             )

      submit(lv, %{"excluded_actions" => ["", "sso_login"]})
      assert has_element?(lv, "#destination-form-resend-note")
      fresh = Repo.get!(Destination, destination.id)
      assert fresh.excluded_actions == ["sso_login"]
      assert fresh.filter_version == destination.filter_version + 1

      # A change without a waiting batch shows no note.
      other = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, edit_path(other))
      submit(lv, %{"include_personal_data" => "false"})
      refute has_element?(lv, "#destination-form-resend-note")
      refute Repo.get!(Destination, other.id).include_personal_data
    end

    test "the type can't change on edit and a start-point param changes nothing",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      cursor = Repo.get!(Cursor, destination.id)
      {:ok, lv, _html} = live(conn, edit_path(destination))

      submit(lv, %{"kind" => "splunk_hec", "start_from" => "all", "name" => "Same kind"})

      fresh = Repo.get!(Destination, destination.id)
      assert fresh.kind == :https
      assert fresh.name == "Same kind"
      assert Repo.get!(Cursor, destination.id) == cursor
    end

    test "a second org-admin's save after another's is told to reload", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, first, _html} = live(conn, edit_path(destination))
      {:ok, second, _html} = live(conn, edit_path(destination))

      submit(first, %{"name" => "First"})
      render_async(first, 5_000)
      html = submit(second, %{"name" => "Second"})

      assert html =~ "This destination changed since you opened it"
      assert Repo.get!(Destination, destination.id).name == "First"
    end

    test "a destination deleted while its form is open goes back to the list",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, edit_path(destination))
      Repo.delete!(destination)

      assert {:error, {:live_redirect, %{to: "/org/audit/streaming"}}} =
               submit(lv, %{"name" => "Gone"})

      assert {:error, {:live_redirect, %{to: "/org/audit/streaming", flash: flash}}} =
               live(conn, edit_path(destination))

      assert flash["error"] == "Destination not found."
    end

    test "validate after the destination is deleted goes back to the list", %{
      conn: conn,
      org: org
    } do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, edit_path(destination))
      Repo.delete!(destination)

      assert {:error, {:live_redirect, %{to: "/org/audit/streaming"}}} =
               change(lv, %{"name" => "Gone"})
    end
  end

  describe "access" do
    test "a member and another Organization's org-admin are refused on mount and on save",
         %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      member = user_fixture()
      organization_member_fixture(org, member)

      for user <- [member, admin_fixture()],
          path <- [~p"/org/audit/streaming/new", edit_path(destination)] do
        assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
                 live(log_in_user(conn, user), path)

        assert flash["error"] == @refusal
      end

      assert [_ | _] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)

      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      assert {:error, {:live_redirect, %{to: "/org/audit/streaming", flash: flash}}} =
               live(log_in_user(conn, other_admin), edit_path(destination))

      assert flash["error"] == "Destination not found."
    end

    test "an org-admin demoted while the form is open is refused on save and nothing is written",
         %{conn: conn, org: org, org_admin: org_admin} do
      destination = destination_fixture(org, :https)
      {:ok, new_lv, _html} = live(conn, ~p"/org/audit/streaming/new")
      {:ok, edit_lv, _html} = live(conn, edit_path(destination))

      demote(org_admin)

      assert {:error, {:redirect, %{to: "/boards"}}} = submit(new_lv, @splunk)
      assert assert_redirect(new_lv, "/boards") == %{"error" => @refusal}

      assert {:error, {:redirect, %{to: "/boards"}}} = submit(edit_lv, %{"name" => "Demoted"})

      assert destinations(org) == [Repo.get!(Destination, destination.id)]
      fresh = Repo.get!(Destination, destination.id)
      assert fresh.name == destination.name
      assert fresh.lock_version == destination.lock_version
      assert AuditLog.list_events(action: :audit_stream_destination_updated) == []
    end

    test "replace and dismiss go through the org-admin check", %{
      conn: conn,
      org: org,
      org_admin: org_admin
    } do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, edit_path(destination))
      demote(org_admin)

      assert {:error, {:redirect, %{to: "/boards"}}} =
               lv |> element("#destination-form-url-replace") |> render_click()
    end
  end

  describe "locales" do
    test "shows the coarse test classes in ja and zh", %{conn: conn} do
      for {locale, transport, msgid} <- [
            {"ja", &Req.Test.transport_error(&1, :econnrefused), "Could not connect"},
            {"zh", &Plug.Conn.send_resp(&1, 401, @body),
             "The destination refused the credentials"}
          ] do
        conn = Plug.Test.init_test_session(conn, %{"locale" => locale})
        Req.Test.stub(Transport, transport)
        {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
        submit(lv, Map.put(@splunk, "name", "#{locale} #{msgid}"))
        render_async(lv, 5_000)

        text =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            Gettext.gettext(KanbanWeb.Gettext, msgid)
          end)

        refute text == msgid, "#{locale} lacks a translation of #{msgid}"
        assert has_element?(lv, "#destination-form-test-result", text), "#{locale}: #{msgid}"
      end
    end

    test "renders in every locale", %{conn: conn, org: org} do
      destination = destination_fixture(org, :datadog)
      make_unreadable!(destination, :credential)

      for locale <- ~w(de en es fr ja pt zh) do
        conn = Plug.Test.init_test_session(conn, %{"locale" => locale})
        {:ok, new_lv, _html} = live(conn, ~p"/org/audit/streaming/new")

        new_html =
          change(new_lv, %{"url" => "https://collector.example.com/x", "start_from" => "all"})

        {:ok, edit_lv, _html} = live(conn, edit_path(destination))

        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          texts = [
            {new_lv, "#destination-form-title",
             Gettext.gettext(KanbanWeb.Gettext, "Add destination")},
            {new_lv, "#destination-form-catch-up-note",
             Gettext.gettext(
               KanbanWeb.Gettext,
               "This sends past events from the audit log, and every org-admin of the Organization will be told."
             )},
            {edit_lv, "#destination-form-credential-unreadable",
             Gettext.gettext(KanbanWeb.Gettext, "Can't be read. Enter it again.")}
          ]

          for {lv, selector, text} <- texts do
            assert has_element?(lv, selector, text), "#{locale}: #{selector}"
          end

          path_error =
            Gettext.gettext(
              KanbanWeb.Gettext,
              "Use the collector path /services/collector or /services/collector/event."
            )

          assert new_html =~ path_error

          if locale != "en" do
            for msgid <- [
                  "Add destination",
                  "Can't be read. Enter it again.",
                  "The waiting batch will be sent again under the new settings.",
                  "Use the collector path /services/collector or /services/collector/event."
                ] do
              refute Gettext.gettext(KanbanWeb.Gettext, msgid) == msgid,
                     "#{locale} lacks a translation of #{msgid}"
            end
          end
        end)
      end
    end
  end

  describe "the list page" do
    test "each row has Edit and the page has Add destination", %{conn: conn, org: org} do
      destination = destination_fixture(org, :https)
      {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")

      assert has_element?(lv, ~s(#add-destination[href="/org/audit/streaming/new"]))
      refute has_element?(lv, "#audit-streaming-add-limit-reason")

      assert has_element?(
               lv,
               ~s(#edit-destination-#{destination.id}[href="/org/audit/streaming/#{destination.id}/edit"])
             )
    end
  end
end

defmodule KanbanWeb.OrgLive.AuditStreamFormGlobalTest do
  # async: false because these tests change the configured maximum, a global
  # setting.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    original = Application.get_env(:kanban, Kanban.AuditStream)

    Application.put_env(
      :kanban,
      Kanban.AuditStream,
      Keyword.put(original || [], :max_destinations, 1)
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.AuditStream, original) end)

    %{conn: log_in_user(conn, org_admin), org: org}
  end

  test "at the limit Add destination is disabled and /new redirects", %{conn: conn, org: org} do
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
    refute has_element?(lv, "#add-destination[disabled]")

    destination_fixture(org, :https)
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming")
    assert has_element?(lv, "#add-destination[disabled]")
    assert has_element?(lv, "#audit-streaming-add-limit-reason", "Delete one to add another.")

    assert {:error, {:live_redirect, %{to: "/org/audit/streaming", flash: flash}}} =
             live(conn, ~p"/org/audit/streaming/new")

    assert flash["error"] =~ "already has 1 destination"
  end

  test "a save that meets the limit goes back to the list", %{conn: conn, org: org} do
    {:ok, lv, _html} = live(conn, ~p"/org/audit/streaming/new")
    destination_fixture(org, :https)

    params = %{
      "kind" => "splunk_hec",
      "name" => "Too many",
      "secret_token" => %{
        "url" => "https://collector.example.com/services/collector",
        "credential" => "splunk-token-0123456789-abcd"
      },
      "start_from" => "now"
    }

    assert {:error, {:live_redirect, %{to: "/org/audit/streaming"}}} =
             lv |> element("#destination-form") |> render_submit(%{"destination" => params})

    assert assert_redirect(lv, "/org/audit/streaming")["error"] =~ "already has 1 destination"
  end
end
