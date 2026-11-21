defmodule KanbanWeb.SeoNoindexTest do
  @moduledoc """
  Which pages ask search engines not to index them (W2890).

  Token, account, unsubscribe, locked-feature, OAuth and every signed-in page
  render `<meta name="robots" content="noindex, nofollow">` (through the
  `:noindex` assign `KanbanWeb.SeoComponents.seo_head/1` reads) and send
  `x-robots-tag: noindex, nofollow`. The `/admin` library dashboards render
  their own layouts, so they carry only the header. Log-in, register and the
  public pages render neither. The router-wiring tests pin the allow-list, so
  a new browser GET route fails here until it is classified. Only GET routes
  are classified, because crawlers fetch and index GET responses, not the
  responses to a POST or DELETE. The non-GET routes that render a page (the
  unsubscribe confirmation POST and the OAuth confirm POST) are noindex
  anyway, through the controller plug or the :put_noindex pipeline.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TwoFactorHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Workspaces.Invitations
  alias KanbanWeb.TwoFactorPending
  alias KanbanWeb.UnsubscribeToken

  @noindex ["noindex, nofollow"]
  @seo_hook {KanbanWeb.SeoOnMount, :noindex}

  # Every live_session in the router, by what it is. A new session fails the
  # wiring test until it is added to one of these lists.
  @signed_in_sessions [:admin, :require_sudo_mode, :require_authenticated_user]
  @public_sessions [:current_user, :public, :public_app_shell]
  # LiveDashboard and ErrorTracker render their own layouts without seo_head,
  # so their noindex is the header from the /admin scope's pipeline.
  @library_sessions [:live_dashboard, :error_tracker_dashboard]

  # The :current_user session mixes the two: these views opt in themselves.
  @noindex_views [
    KanbanWeb.UserLive.TwoFactor,
    KanbanWeb.UserLive.Confirmation,
    KanbanWeb.UserLive.ForgotPassword,
    KanbanWeb.UserLive.ResetPassword,
    KanbanWeb.UserLive.ConfirmationPending,
    KanbanWeb.WorkspaceLive.InvitationAccept
  ]
  @indexable_views [KanbanWeb.UserLive.Registration, KanbanWeb.UserLive.Login]

  # Every GET browser route that stays indexable. A route left off this list
  # and off the noindex pipeline fails "every browser GET route is
  # classified".
  @public_paths [
    "/",
    "/about",
    "/acceptable-use",
    "/HitMe",
    "/pricing",
    "/privacy",
    "/product",
    "/security",
    "/tango",
    "/terms",
    "/workflows",
    "/changelog",
    "/issue",
    "/resources",
    "/resources/:id",
    "/demo",
    "/docs",
    "/docs/:slug",
    "/integrations",
    "/integrations/:runtime",
    "/users/register",
    "/users/log-in"
  ]

  # Noindex through a controller plug rather than the pipeline.
  @controller_noindex_paths [
    "/notifications/unsubscribe",
    "/notifications/unsubscribe/one-click",
    "/releases/confirm",
    "/releases/unsubscribe",
    "/releases/unsubscribe/one-click"
  ]

  defp robots(conn, status \\ 200) do
    conn
    |> html_response(status)
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(head meta[name="robots"]))
    |> LazyHTML.attribute("content")
  end

  defp x_robots(conn), do: get_resp_header(conn, "x-robots-tag")

  defp assert_noindex(conn, status \\ 200) do
    assert robots(conn, status) == @noindex
    assert x_robots(conn) == @noindex
  end

  defp assert_indexable(conn) do
    assert robots(conn) == []
    assert x_robots(conn) == []
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

    sent_invitation_token()
  end

  defp sent_invitation_token do
    receive do
      {:email, %{subject: "You're invited to" <> _, html_body: body}} ->
        [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)}, body)
        token

      {:email, _other} ->
        sent_invitation_token()
    after
      1_000 -> flunk("no invitation email was sent")
    end
  end

  defp oauth_params do
    %{
      "response_type" => "code",
      "client_id" => "stride-ios",
      "redirect_uri" => "com.stridelikeaboss.app:/oauth/callback",
      "code_challenge" => valid_code_challenge(),
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "device_name" => "iPhone 15",
      "device_class" => "phone"
    }
  end

  defp live_routes do
    for %{metadata: %{phoenix_live_view: {view, _action, _opts, session}}} = route <-
          Phoenix.Router.routes(KanbanWeb.Router),
        do: {route.path, view, session}
  end

  defp pipe_through(verb, path) do
    concrete = String.replace(path, ~r{:[a-z_]+}, "x")
    Phoenix.Router.route_info(KanbanWeb.Router, verb, concrete, "").pipe_through
  end

  defp mount_hook_ids(view), do: Enum.map(view.__live__().lifecycle.mount, & &1.id)

  describe "token and account pages" do
    test "password reset, email confirmation, two-factor, confirmation-pending and invitation pages render robots noindex",
         %{conn: conn} do
      user = user_fixture()

      reset =
        extract_user_token(&Accounts.deliver_user_reset_password_instructions(user, &1))

      assert_noindex(get(conn, ~p"/users/reset-password/#{reset}"))

      unconfirmed = unconfirmed_user_fixture()

      confirm =
        extract_user_token(&Accounts.deliver_user_confirmation_instructions(unconfirmed, &1))

      assert_noindex(get(build_conn(), ~p"/users/confirm/#{confirm}"))

      two_factor_user = user_fixture()
      enroll(two_factor_user)
      marker = TwoFactorPending.new(two_factor_user.id, false, System.os_time(:second))

      build_conn()
      |> init_test_session(two_factor_pending: marker)
      |> get(~p"/users/two-factor")
      |> assert_noindex()

      assert_noindex(
        get(build_conn(), ~p"/users/confirmation-pending?email=someone@example.test")
      )

      assert_noindex(get(build_conn(), ~p"/users/forgot-password"))

      token = invitation_token("invitee@example.test")
      assert_noindex(get(build_conn(), ~p"/invitations/#{token}"))
    end

    test "the invitation page is noindex before and after the invitee signs in" do
      email = "rights.invitee@example.test"
      token = invitation_token(email)

      assert_noindex(get(build_conn(), ~p"/invitations/#{token}"))

      invitee = user_fixture(%{email: email})

      build_conn()
      |> log_in_user(invitee)
      |> get(~p"/invitations/#{token}")
      |> assert_noindex()
    end

    test "an invalid token's redirect still carries X-Robots-Tag", %{conn: conn} do
      conn = get(conn, ~p"/users/reset-password/not-a-real-token")

      assert redirected_to(conn) == ~p"/"
      assert x_robots(conn) == @noindex
    end

    test "the single sign-on redirects carry X-Robots-Tag" do
      for path <- [~p"/users/sso/start", ~p"/users/sso/callback"] do
        conn = get(build_conn(), path)

        assert conn.status == 302
        assert x_robots(conn) == @noindex, "#{path} lacks X-Robots-Tag"
      end
    end

    test "an unknown guide's Not Found page is noindex", %{conn: conn} do
      assert robots(get(conn, ~p"/resources/no-such-guide")) == @noindex
    end

    test "two-factor without a pending sign-in redirects with X-Robots-Tag", %{conn: conn} do
      conn = get(conn, ~p"/users/two-factor")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert x_robots(conn) == @noindex
    end
  end

  describe "public pages" do
    test "home, pricing, resources and the log-in page render no robots tag", %{conn: conn} do
      for path <- ["/", "/pricing", "/resources", "/users/log-in"] do
        assert_indexable(get(conn, path))
      end
    end

    test "every public route stays indexable" do
      for path <- @public_paths do
        concrete =
          path
          |> String.replace(":id", "creating-your-first-board")
          |> String.replace(":slug", "mcp")
          |> String.replace(":runtime", "codex")

        conn = get(build_conn(), concrete)

        assert robots(conn) == [], "#{path} renders a robots tag"
        assert x_robots(conn) == [], "#{path} sends X-Robots-Tag"
      end
    end
  end

  describe "controller routes" do
    setup do
      user = user_fixture()
      %{user: user, token: UnsubscribeToken.sign(user.id, :review_requested)}
    end

    test "the noindex response also carries an X-Robots-Tag noindex header", ctx do
      conn = get(build_conn(), ~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}")
      assert_noindex(conn)

      post_conn =
        build_conn()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}", %{
          "List-Unsubscribe" => "One-Click"
        })

      assert post_conn.status == 200
      assert x_robots(post_conn) == @noindex

      refused =
        build_conn()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/notifications/unsubscribe/one-click?#{[token: ctx.token <> "x"]}", %{
          "List-Unsubscribe" => "One-Click"
        })

      assert refused.status == 400
      assert x_robots(refused) == @noindex

      signed_in = build_conn() |> log_in_user(ctx.user)
      assert_noindex(get(signed_in, authorize_path(oauth_params())))

      too_long =
        oauth_params()
        |> Map.merge(%{
          "device_name" => String.duplicate("日", 255),
          "state" => String.duplicate("%", 255)
        })

      assert_noindex(get(build_conn(), authorize_path(too_long)), 400)
    end
  end

  describe "release announcement list pages" do
    test "the confirm and unsubscribe pages render robots noindex, valid token or not" do
      email = "noindex-#{System.unique_integer([:positive])}@example.test"

      :ok =
        Kanban.Subscribers.subscribe(email, ip: {127, 0, 0, 1}, locale: "en", consent_text: "ok")

      {confirm, unsubscribe} =
        receive do
          {:email, %{text_body: body}} ->
            [confirm] =
              Regex.run(~r{/releases/confirm\?token=([A-Za-z0-9_-]+)}, body,
                capture: :all_but_first
              )

            [unsubscribe] =
              Regex.run(~r{/releases/unsubscribe\?token=([A-Za-z0-9_-]+)}, body,
                capture: :all_but_first
              )

            {confirm, unsubscribe}
        end

      assert_noindex(get(build_conn(), ~p"/releases/confirm?#{[token: confirm]}"))
      assert_noindex(get(build_conn(), ~p"/releases/unsubscribe?#{[token: unsubscribe]}"))

      # A browser opening the one-click URL is redirected to the unsubscribe
      # page; the redirect itself still carries the noindex header.
      one_click = get(build_conn(), ~p"/releases/unsubscribe/one-click?#{[token: unsubscribe]}")
      assert redirected_to(one_click) == ~p"/releases/unsubscribe?#{[token: unsubscribe]}"
      assert x_robots(one_click) == @noindex

      assert_noindex(get(build_conn(), ~p"/releases/confirm?#{[token: "nope"]}"), 400)
      assert_noindex(get(build_conn(), ~p"/releases/unsubscribe?#{[token: "nope"]}"), 400)
    end
  end

  describe "unsubscribe and locked-feature pages" do
    test "the unsubscribe page and the locked-feature page render robots noindex" do
      user = user_fixture()
      token = UnsubscribeToken.sign(user.id, :review_requested)

      assert_noindex(get(build_conn(), ~p"/notifications/unsubscribe?#{[token: token]}"))

      assert_noindex(
        get(build_conn(), ~p"/notifications/unsubscribe?#{[token: token <> "x"]}"),
        400
      )

      # The locked-feature route only redirects, so it has no page to carry a
      # meta tag; the header is its noindex, signed in or not.
      signed_in = get(log_in_user(build_conn(), user), ~p"/locked/audit")
      assert redirected_to(signed_in) =~ "/pricing"
      assert x_robots(signed_in) == @noindex

      signed_out = get(build_conn(), ~p"/locked/audit")
      assert redirected_to(signed_out) == ~p"/users/log-in"
      assert x_robots(signed_out) == @noindex
    end
  end

  describe "signed-in pages" do
    setup :register_and_log_in_user

    test "a signed-in board page renders robots noindex", %{conn: conn} do
      assert_noindex(get(conn, ~p"/boards"))
      assert_noindex(get(conn, ~p"/users/settings"))
    end
  end

  describe "router wiring" do
    test "every live_session is classified as signed-in or public" do
      sessions = live_routes() |> Enum.map(fn {_path, _view, s} -> s.name end) |> Enum.uniq()

      assert Enum.sort(sessions) ==
               Enum.sort(@signed_in_sessions ++ @public_sessions ++ @library_sessions)
    end

    test "the admin library dashboards pipe :put_noindex" do
      for {path, _view, session} <- live_routes(), session.name in @library_sessions do
        assert :put_noindex in pipe_through("GET", path), "#{path} lacks :put_noindex"
      end
    end

    test "every signed-in live_session runs SeoOnMount and pipes :put_noindex" do
      for {path, _view, session} <- live_routes(), session.name in @signed_in_sessions do
        assert @seo_hook in Enum.map(session.extra.on_mount, & &1.id),
               "#{session.name} lacks SeoOnMount"

        assert :put_noindex in pipe_through("GET", path), "#{path} lacks :put_noindex"
      end
    end

    test "only the token and account views of :current_user are noindex" do
      views =
        for {_path, view, %{name: :current_user}} <- live_routes(), uniq: true, do: view

      assert Enum.sort(views) == Enum.sort(@noindex_views ++ @indexable_views)

      for {path, view, %{name: :current_user}} <- live_routes() do
        if view in @noindex_views do
          assert @seo_hook in mount_hook_ids(view), "#{inspect(view)} lacks SeoOnMount"
          assert :put_noindex in pipe_through("GET", path), "#{path} lacks :put_noindex"
        else
          refute @seo_hook in mount_hook_ids(view)
          refute :put_noindex in pipe_through("GET", path)
        end
      end
    end

    test "no public live_session or public view runs SeoOnMount" do
      for {_path, view, session} <- live_routes(),
          session.name in @public_sessions,
          view not in @noindex_views do
        refute @seo_hook in Enum.map(session.extra.on_mount, & &1.id)
        refute @seo_hook in mount_hook_ids(view)
      end
    end

    test "every browser GET route is classified" do
      unclassified =
        for %{verb: :get, path: path} <- Phoenix.Router.routes(KanbanWeb.Router),
            pipes = pipe_through("GET", path),
            :browser in pipes,
            :put_noindex not in pipes,
            path not in (@public_paths ++ @controller_noindex_paths),
            do: path

      assert unclassified == [],
             "classify these routes as public or noindex: #{inspect(unclassified)}"
    end

    test "the public allow-list names no noindex route" do
      for path <- @public_paths do
        refute :put_noindex in pipe_through("GET", path), "#{path} pipes :put_noindex"
      end
    end
  end

  defp authorize_path(params), do: "/oauth/authorize?" <> URI.encode_query(params)
end
