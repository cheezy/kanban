defmodule KanbanWeb.AnalyticsTest do
  @moduledoc """
  Umami analytics (W2897): which pages render the tracker, what the tag
  carries, how the CSP widens, the one-shot signup event and the event
  attributes on the calls to action.

  Umami is configured with fake values through the application environment,
  so the module is not async; every test restores the environment it found.
  """
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts
  alias Kanban.Workspaces.Invitations
  alias KanbanWeb.Analytics
  alias KanbanWeb.Plugs.CspNonce

  @website_id "0b4c2a3e-1f2d-4c5b-8a9e-7d6f5e4c3b2a"
  @config [
    script_url: "https://umami.example.test/script.js",
    website_id: @website_id,
    host_url: "https://collect.example.test"
  ]

  @tracker "script[data-website-id]"
  @hook {KanbanWeb.AnalyticsOnMount, :track}
  @opted_in_views [
    KanbanWeb.UserLive.Registration,
    KanbanWeb.UserLive.Login,
    KanbanWeb.UserLive.ConfirmationPending
  ]

  setup do
    saved = Application.fetch_env(:kanban, :umami)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:kanban, :umami, value)
        :error -> Application.delete_env(:kanban, :umami)
      end
    end)

    :ok
  end

  defp configure(config \\ @config), do: Application.put_env(:kanban, :umami, config)
  defp unconfigure, do: Application.delete_env(:kanban, :umami)

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp tracker_tags(conn), do: conn |> document() |> LazyHTML.query(@tracker) |> Enum.to_list()

  defp csp(conn) do
    [header] = get_resp_header(conn, "content-security-policy")
    header
  end

  # Parses a policy into %{name => sources}. A browser enforces only the first
  # of two same-named directives, so a map that silently kept the last one could
  # pass a widening test while the header carries a wider directive the browser
  # obeys. A repeated name (CSP names are case-insensitive) fails the test, and
  # so does a comma, which would start a second policy this map cannot see.
  # Case and whitespace follow CSP's ASCII rules: only tab, LF, FF, CR and space
  # separate tokens, and only A-Z fold to lower case.
  defp directives(policy) do
    if String.contains?(policy, ","),
      do: flunk("CSP joins a second policy with a comma: #{policy}")

    policy
    |> String.split(";")
    |> Enum.map(&String.split(&1, ~r/[\t\n\f\r ]+/, trim: true))
    |> Enum.reject(&(&1 == []))
    |> Enum.reduce(%{}, &put_directive(&1, &2, policy))
  end

  defp put_directive([name | sources], acc, policy) do
    name = String.downcase(name, :ascii)

    if Map.has_key?(acc, name), do: flunk("CSP repeats directive #{name}: #{policy}")

    Map.put(acc, name, sources)
  end

  defp nonce_of(policy) do
    [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, policy)
    nonce
  end

  defp invitation_token(email) do
    organization = organization_fixture(%{name: "Acme Org"})
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization, name: "Platform")

    {:ok, _invitation} =
      Invitations.invite_to_workspace(
        admin,
        workspace,
        %{"email" => email, "role" => "member"},
        &"https://example.test/invitations/#{&1}"
      )

    receive_invitation_token()
  end

  defp receive_invitation_token do
    receive do
      {:email, %{subject: "You're invited to" <> _, html_body: body}} ->
        [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)}, body)
        token

      {:email, _other} ->
        receive_invitation_token()
    after
      1_000 -> flunk("no invitation email was sent")
    end
  end

  defp live_routes do
    for %{metadata: %{phoenix_live_view: {view, _action, _opts, session}}} <-
          Phoenix.Router.routes(KanbanWeb.Router),
        do: {view, session}
  end

  defp register(conn) do
    post(conn, ~p"/users/register", %{
      "user" => %{"email" => unique_user_email(), "password" => valid_user_password()}
    })
  end

  describe "config/0 and origin/1" do
    test "returns the settings and both origins when fully configured" do
      configure()

      assert Analytics.config() == %{
               script_url: "https://umami.example.test/script.js",
               website_id: @website_id,
               host_url: "https://collect.example.test",
               script_origin: "https://umami.example.test",
               connect_origin: "https://collect.example.test"
             }

      assert Analytics.enabled?()
    end

    test "is off when the config is absent, partial or malformed" do
      unconfigure()
      refute Analytics.config()
      refute Analytics.enabled?()

      for broken <- [
            Keyword.delete(@config, :host_url),
            Keyword.put(@config, :website_id, "not-a-uuid"),
            Keyword.put(@config, :script_url, "http://umami.example.test/script.js"),
            Keyword.put(@config, :host_url, "https://user:pass@collect.example.test"),
            Keyword.put(@config, :script_url, "https://*.example.test/script.js"),
            Keyword.put(@config, :host_url, "https://collect.example.test;script-src"),
            Keyword.put(@config, :script_url, nil),
            "not a keyword list"
          ] do
        configure(broken)
        assert Analytics.config() == nil, "expected #{inspect(broken)} to turn analytics off"
      end
    end

    test "origin/1 keeps a non-default port and lower-cases the host" do
      assert Analytics.origin("https://Umami.Example.test:8443/x.js") ==
               {:ok, "https://umami.example.test:8443"}

      assert Analytics.origin("https://umami.example.test:443/x.js") ==
               {:ok, "https://umami.example.test"}

      assert Analytics.origin("http://umami.example.test") == :error
      assert Analytics.origin("https:///nohost") == :error
      assert Analytics.origin("https://*.example.test/x.js") == :error
      assert Analytics.origin("https://a.example.test;img-src/x.js") == :error
      assert Analytics.origin("https://a'b.example.test") == :error
      assert Analytics.origin(nil) == :error
    end
  end

  describe "the tracker tag" do
    test "with Umami configured, the tag carries data-website-id, data-host-url, data-domains, data-exclude-search, data-exclude-hash and the CSP nonce",
         %{conn: conn} do
      configure()
      conn = get(conn, ~p"/pricing")

      assert [tag] = tracker_tags(conn)
      attr = fn name -> tag |> LazyHTML.attribute(name) |> List.first() end

      assert attr.("src") == "https://umami.example.test/script.js"
      assert attr.("data-website-id") == @website_id
      assert attr.("data-host-url") == "https://collect.example.test"
      assert attr.("data-domains") == KanbanWeb.Endpoint.host()
      assert attr.("data-exclude-search") == "true"
      assert attr.("data-exclude-hash") == "true"
      assert attr.("data-before-send") == "strideAnalyticsBeforeSend"
      assert attr.("defer") == ""
      assert attr.("nonce") == nonce_of(csp(conn))

      refute conn |> html_response(200) =~ "data-distinct-id"
      refute conn |> html_response(200) =~ "umami.identify"
    end

    test "the tracker comes before app.js, so window.umami exists when the hooks mount",
         %{conn: conn} do
      configure()

      # One page per root layout that loads the tracker: /pricing renders
      # marketing, /users/register renders root and /about renders app_chrome.
      for path <- [~p"/pricing", ~p"/users/register", ~p"/about"] do
        html = conn |> recycle() |> get(path) |> html_response(200)

        {tracker, _} = :binary.match(html, "data-website-id")
        {app_js, _} = :binary.match(html, "/assets/js/app.js")
        assert tracker < app_js, "#{path} loads app.js before the tracker"
      end
    end

    test "nothing renders and the CSP is unchanged when the Umami config is absent",
         %{conn: conn} do
      unconfigure()
      conn = get(conn, ~p"/pricing")
      policy = csp(conn)

      assert tracker_tags(conn) == []
      nonce = nonce_of(policy)

      assert policy == CspNonce.policy(nonce)
      assert directives(policy)["script-src"] == ["'self'", "'nonce-#{nonce}'"]
      refute policy =~ "connect-src"
      refute policy =~ "example.test"
    end
  end

  describe "the CSP" do
    test "the CSP adds exactly the script origin to script-src and the collection origin to connect-src, with no wildcard",
         %{conn: conn} do
      configure()
      policy = conn |> get(~p"/pricing") |> csp()
      nonce = nonce_of(policy)

      unconfigure()
      plain = directives(CspNonce.policy(nonce))
      widened = directives(policy)

      assert widened["script-src"] == plain["script-src"] ++ ["https://umami.example.test"]
      assert widened["connect-src"] == ["'self'", "https://collect.example.test"]
      refute Map.has_key?(plain, "connect-src")

      assert Map.drop(widened, ["script-src", "connect-src"]) ==
               Map.drop(plain, ["script-src", "connect-src"])

      refute policy =~ "*"
    end

    test "a malformed config widens nothing", %{conn: conn} do
      configure(Keyword.put(@config, :host_url, "http://collect.example.test"))
      conn = get(conn, ~p"/pricing")

      policy = csp(conn)

      nonce = nonce_of(policy)

      refute policy =~ "example.test"
      assert directives(policy)["script-src"] == ["'self'", "'nonce-#{nonce}'"]
      refute policy =~ "connect-src"
      assert tracker_tags(conn) == []
    end

    test "the policy parser rejects a repeated script-src" do
      policy = "default-src 'self'; script-src 'self'; script-src https://evil.example.test"

      error = assert_raise ExUnit.AssertionError, fn -> directives(policy) end
      assert error.message =~ "CSP repeats directive script-src"
    end

    test "the policy parser treats directive names that differ only in case as repeats" do
      policy = "script-src 'self'; SCRIPT-SRC https://evil.example.test"

      error = assert_raise ExUnit.AssertionError, fn -> directives(policy) end
      assert error.message =~ "CSP repeats directive script-src"
    end

    test "the policy parser splits sources on runs of whitespace and ignores a trailing semicolon" do
      assert directives("default-src  'self'; \t ;  script-src 'self'\t 'nonce-abc'  ; ") == %{
               "default-src" => ["'self'"],
               "script-src" => ["'self'", "'nonce-abc'"]
             }
    end

    test "the policy parser rejects a second policy joined with a comma" do
      policy = "script-src 'self', script-src https://evil.example.test"

      error = assert_raise ExUnit.AssertionError, fn -> directives(policy) end
      assert error.message =~ "CSP joins a second policy with a comma"
    end

    test "the policy parser follows CSP's ASCII rules for whitespace and case" do
      assert directives("script-src 'self'\v'nonce-abc'") == %{
               "script-src" => ["'self'\v'nonce-abc'"]
             }

      assert directives("worker-src 'self'; wor\u212Aer-src https://evil.example.test") == %{
               "worker-src" => ["'self'"],
               "wor\u212Aer-src" => ["https://evil.example.test"]
             }
    end
  end

  describe "which pages load the tracker" do
    test "every path in KanbanWeb.SeoXML.public_paths/0, /users/register and /users/log-in renders the script" do
      configure()
      how_to = KanbanWeb.ResourcesLive.HowToData.all_how_tos() |> hd()

      paths =
        KanbanWeb.SeoXML.public_paths() ++
          ["/resources/#{how_to.id}", "/users/register", "/users/log-in"]

      for path <- paths do
        conn = get(build_conn(), path)
        assert conn.status == 200, "#{path} answered #{conn.status}"
        assert [_tag] = tracker_tags(conn), "#{path} does not render the tracker"
      end
    end

    test "a signed-in user still gets the tracker on /pricing, and never on boards or settings",
         %{conn: conn} do
      configure()
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      board = board_fixture(user)

      assert [_tag] = conn |> get(~p"/pricing") |> tracker_tags()

      for path <- [~p"/boards", ~p"/boards/#{board}", ~p"/users/settings"] do
        assert conn |> get(path) |> tracker_tags() == [], "#{path} renders the tracker"
      end
    end

    test "signed-in pages and the token pages (/users/confirm/:token, /users/reset-password/:token, /invitations/:token) never render the script" do
      configure()
      user = user_fixture()

      reset = extract_user_token(&Accounts.deliver_user_reset_password_instructions(user, &1))
      unconfirmed = unconfirmed_user_fixture()

      confirm =
        extract_user_token(&Accounts.deliver_user_confirmation_instructions(unconfirmed, &1))

      invitation = invitation_token("invitee@example.test")

      for path <- [
            ~p"/users/reset-password/#{reset}",
            ~p"/users/confirm/#{confirm}",
            ~p"/invitations/#{invitation}",
            ~p"/users/forgot-password"
          ] do
        assert build_conn() |> get(path) |> tracker_tags() == [], "#{path} renders the tracker"
      end
    end

    test "only the public live_sessions and the three auth views opt in" do
      for {view, session} <- live_routes() do
        session_hooks = Enum.map(session.extra.on_mount, & &1.id)
        view_hooks = Enum.map(view.__live__().lifecycle.mount, & &1.id)

        cond do
          session.name in [:public, :public_app_shell] ->
            assert @hook in session_hooks, "#{session.name} lacks AnalyticsOnMount"

          view in @opted_in_views ->
            refute @hook in session_hooks
            assert @hook in view_hooks, "#{inspect(view)} lacks AnalyticsOnMount"

          true ->
            refute @hook in session_hooks, "#{session.name} opts in to analytics"

            refute @hook in (view_hooks -- session_hooks),
                   "#{inspect(view)} opts in to analytics"
        end
      end
    end
  end

  describe "the signup event" do
    test "/users/confirmation-pending sends the signup event once after a registration and not on a reload or a direct visit",
         %{conn: conn} do
      configure()
      conn = register(conn)
      path = redirected_to(conn)

      first = conn |> recycle() |> get(path)

      assert [element] =
               first
               |> document()
               |> LazyHTML.query("#analytics-signup-event[phx-hook=AnalyticsSignup]")
               |> Enum.to_list()

      assert element |> LazyHTML.attribute("hidden") == [""]
      assert [_tag] = tracker_tags(first)

      # The flash was consumed: a reload carries no flag.
      reload = first |> recycle() |> get(path) |> html_response(200)
      refute reload =~ "analytics-signup-event"

      direct = build_conn() |> get(path) |> html_response(200)
      refute direct =~ "analytics-signup-event"

      no_email = build_conn() |> get(~p"/users/confirmation-pending") |> html_response(200)
      refute no_email =~ "analytics-signup-event"
    end

    test "the connected LiveView keeps the signup element so its hook can mount",
         %{conn: conn} do
      configure()
      conn = register(conn)

      {:ok, view, _html} = conn |> recycle() |> live(redirected_to(conn))

      assert has_element?(view, "#analytics-signup-event[phx-hook=AnalyticsSignup]")
    end

    test "no signup element renders when Umami is not configured", %{conn: conn} do
      unconfigure()
      conn = register(conn)

      html = conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)
      refute html =~ "analytics-signup-event"
    end
  end

  describe "event attributes" do
    @events ~w(get-started-clicked github-clicked)
    @locations ~w(nav hero closing pricing product workflows demo footer docs-source
                   integration-listing integration-docs integration-install-note security issue
                   workflows-runtime compare-corrections changelog)

    defp events_on(path) do
      build_conn()
      |> get(path)
      |> document()
      |> LazyHTML.query("[data-umami-event]")
      |> Enum.map(fn node ->
        {node |> LazyHTML.attribute("data-umami-event") |> hd(),
         node |> LazyHTML.attribute("data-umami-event-location") |> hd()}
      end)
    end

    test "the GitHub links and the sign-up calls to action carry their data-umami-event names and fixed properties" do
      expected = %{
        "/" => [
          {"get-started-clicked", "nav"},
          {"get-started-clicked", "hero"},
          {"get-started-clicked", "closing"},
          {"github-clicked", "footer"}
        ],
        "/pricing" => [{"get-started-clicked", "pricing"}],
        "/product" => [{"get-started-clicked", "product"}],
        "/workflows" => [
          {"get-started-clicked", "workflows"},
          {"github-clicked", "workflows"},
          {"github-clicked", "workflows-runtime"}
        ],
        "/compare/linear" => [{"github-clicked", "compare-corrections"}],
        "/compare/jira" => [{"github-clicked", "compare-corrections"}],
        "/compare/github-projects" => [{"github-clicked", "compare-corrections"}],
        "/changelog" => [{"github-clicked", "changelog"}],
        "/security" => [{"github-clicked", "security"}],
        "/issue" => [{"github-clicked", "issue"}],
        "/integrations/codex" => [
          {"github-clicked", "integration-listing"},
          {"github-clicked", "integration-docs"},
          {"github-clicked", "integration-install-note"}
        ],
        "/demo" => [{"get-started-clicked", "demo"}],
        "/docs/getting-started-with-ai" => [{"github-clicked", "docs-source"}]
      }

      for {path, wanted} <- expected do
        found = events_on(path)

        for event <- wanted do
          assert event in found, "#{path} lacks #{inspect(event)}; found #{inspect(found)}"
        end

        for {name, location} <- found do
          assert name in @events, "#{path} sends an unlisted event #{name}"
          assert location in @locations, "#{path} sends an unlisted location #{location}"
        end
      end
    end

    test "only a runtime with an install note sends the integration-install-note event" do
      for runtime <- KanbanWeb.Integrations.all() do
        sent =
          ~p"/integrations/#{runtime.slug}"
          |> events_on()
          |> Enum.count(&(&1 == {"github-clicked", "integration-install-note"}))

        assert sent == if(runtime.install_note, do: 1, else: 0), runtime.slug
      end
    end

    test "every runtime card on /workflows and both plugin links on /changelog send github-clicked" do
      runtime_events =
        ~p"/workflows"
        |> events_on()
        |> Enum.count(&(&1 == {"github-clicked", "workflows-runtime"}))

      assert runtime_events == length(KanbanWeb.PageHTML.workflow_runtimes())
      assert runtime_events == 6

      changelog_events =
        ~p"/changelog"
        |> events_on()
        |> Enum.count(&(&1 == {"github-clicked", "changelog"}))

      assert changelog_events == 2
    end

    test "every comparison page sends compare-corrections exactly once" do
      for slug <- KanbanWeb.Comparisons.slugs() do
        sent =
          ~p"/compare/#{slug}"
          |> events_on()
          |> Enum.count(&(&1 == {"github-clicked", "compare-corrections"}))

        assert sent == 1, slug
      end
    end

    test "links to GitHub pages that are not Stride's own repositories stay untagged" do
      for {path, selector} <- [
            {~p"/changelog", ~s{a[href="https://github.com/openai/codex"]}},
            {~p"/compare/github-projects", ~s{a[href^="https://docs.github.com/"]}}
          ] do
        links =
          build_conn()
          |> get(path)
          |> document()
          |> LazyHTML.query(selector)
          |> Enum.to_list()

        assert links != [], "#{path} has no #{selector} link to check"

        for link <- links do
          assert LazyHTML.attribute(link, "data-umami-event") == [], "#{path} tags #{selector}"
        end
      end
    end

    test "install commands carry the runtime slug for the copy event" do
      for runtime <- KanbanWeb.Integrations.all() do
        commands =
          build_conn()
          |> get(~p"/integrations/#{runtime.slug}")
          |> document()
          |> LazyHTML.query("code[data-install-command]")
          |> Enum.to_list()

        assert commands != []

        for command <- commands do
          assert LazyHTML.attribute(command, "data-runtime") == [runtime.slug]
          assert runtime.slug =~ ~r/\A[a-z0-9-]{1,40}\z/
        end
      end
    end
  end
end
