defmodule KanbanWeb.SAMLControllerTest do
  # async: false: the rate limit test changes the global Kanban.RateLimit env.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.SSOFixtures

  alias Kanban.Accounts
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SAMLTestHelpers
  alias Kanban.SSO.SAML.Request
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  @refused "Single sign-on could not sign you in."

  setup_all do
    %{idp: SAMLTestHelpers.idp()}
  end

  setup %{idp: idp} do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization).domain
    connection = saml_connection_fixture(organization, idp.pem)
    %{organization: organization, domain: domain, connection: connection}
  end

  # Starts a SAML sign-in through the domain entry point and returns the
  # conn, the RelayState and the AuthnRequest ID.
  defp start(conn, domain) do
    conn = get(conn, ~p"/users/sso/start?#{[domain: domain]}")
    location = redirected_to(conn, 302)
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    request = Repo.get_by!(Request, relay_token: query["RelayState"])
    {conn, query["RelayState"], request.request_id, location}
  end

  # The same browser posting back: a fresh conn carrying the start conn's
  # cookies (the signed RelayState binding among them).
  defp browser(start_conn), do: recycle(start_conn)

  defp acs(organization_id, params, conn \\ build_conn()),
    do: post(conn, ~p"/users/sso/saml/#{organization_id}/acs", params)

  defp sign_in(ctx, response_opts \\ []) do
    {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)

    response =
      SAMLTestHelpers.response(
        ctx.idp,
        response_opts ++
          [
            organization_id: ctx.organization.id,
            request_id: request_id,
            email: "pat@#{ctx.domain}"
          ]
      )

    params = %{"SAMLResponse" => response, "RelayState" => relay}
    {acs(ctx.organization.id, params, browser(start_conn)), params}
  end

  defp refusal_reasons do
    [action: "sso_login_refused"]
    |> AuditLog.list_events()
    |> Enum.map(& &1.metadata["reason"])
    |> Enum.sort()
  end

  describe "GET /users/sso/start for a SAML Organization" do
    test "redirects to the identity provider with an AuthnRequest and a stored request",
         %{conn: conn} = ctx do
      {conn, relay, request_id, location} = start(conn, String.upcase(ctx.domain))

      assert String.starts_with?(location, SAMLTestHelpers.sso_url() <> "?")
      assert SAMLTestHelpers.authn_request_xml(location) =~ ~s(ID="#{request_id}")
      refute get_session(conn, "sso_flow")

      request = Repo.get_by!(Request, relay_token: relay)
      assert request.sso_connection_id == ctx.connection.id
      assert DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt
    end

    test "keeps a local return path and drops any other", %{conn: conn} = ctx do
      conn = Plug.Test.init_test_session(conn, %{user_return_to: "/boards/42"})
      {_conn, relay, _id, _location} = start(conn, ctx.domain)
      assert Repo.get_by!(Request, relay_token: relay).return_to == "/boards/42"

      for path <- ["//evil.example/x", "https://evil.example", "/\\evil.example"] do
        conn = Plug.Test.init_test_session(build_conn(), %{user_return_to: path})
        {_conn, relay, _id, _location} = start(conn, ctx.domain)
        assert is_nil(Repo.get_by!(Request, relay_token: relay).return_to)
      end
    end

    test "a disabled SAML connection is not available", %{conn: conn} = ctx do
      ctx.connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
      conn = get(conn, ~p"/users/sso/start?#{[domain: ctx.domain]}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
    end
  end

  describe "POST /users/sso/saml/:organization_id/acs" do
    test "a valid assertion signs in a new member without a CSRF token or session", ctx do
      {conn, _params} = sign_in(ctx)

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)

      assert get_session(conn, OrganizationTwoFactorGate.sso_session_key()) ==
               ctx.organization.id

      user = Accounts.get_user_by_email("pat@#{ctx.domain}")
      assert user.confirmed_at

      assert %OrganizationMember{role: :member, organization_id: organization_id} =
               Organizations.get_membership(user)

      assert organization_id == ctx.organization.id

      assert [event] = AuditLog.list_events(action: "sso_login")
      assert event.organization_id == ctx.organization.id
      assert event.metadata["protocol"] == "saml"
    end

    test "binds the sign-in to the browser with a SameSite=None cookie", ctx do
      {start_conn, relay, _request_id, _location} = start(build_conn(), ctx.domain)

      cookie = start_conn.resp_cookies["_kanban_saml_relay"]
      assert cookie.same_site == "None"
      assert cookie.secure
      assert cookie.http_only
      assert cookie.path == "/users/sso/saml"
      refute cookie.value == relay
    end

    test "a response posted from another browser is refused (login CSRF)", ctx do
      # The attacker's own sign-in: a valid response and RelayState for it.
      {start_conn, _relay, _id, _location} = start(build_conn(), ctx.domain)
      {other_conn, _relay, _id, _location} = start(build_conn(), ctx.domain)

      # Posted with no binding cookie, then with another sign-in's cookie,
      # each time a fresh request and assertion, so only the binding refuses.
      for conn <- [build_conn(), browser(other_conn)] do
        {_attacker, relay, request_id, _location} = start(build_conn(), ctx.domain)

        response =
          SAMLTestHelpers.response(ctx.idp,
            organization_id: ctx.organization.id,
            request_id: request_id,
            email: "pat@#{ctx.domain}"
          )

        conn =
          acs(ctx.organization.id, %{"SAMLResponse" => response, "RelayState" => relay}, conn)

        assert redirected_to(conn) == ~p"/users/log-in"
        refute get_session(conn, :user_token)
      end

      refute Accounts.get_user_by_email("pat@#{ctx.domain}")
      assert refusal_reasons() == ["browser_mismatch", "browser_mismatch"]
      assert start_conn.resp_cookies["_kanban_saml_relay"]
    end

    test "deletes the binding cookie", ctx do
      {conn, _params} = sign_in(ctx)
      assert conn.resp_cookies["_kanban_saml_relay"].max_age == 0
    end

    test "returns to the stored local path", ctx do
      conn = Plug.Test.init_test_session(build_conn(), %{user_return_to: "/boards/42"})
      {start_conn, relay, request_id, _location} = start(conn, ctx.domain)

      response =
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@#{ctx.domain}"
        )

      # The IdP's cross-site POST carries the relay cookie but not the Lax
      # session cookie, so the path can only come from the stored request.
      %{value: relay_cookie} = start_conn.resp_cookies["_kanban_saml_relay"]
      acs_conn = put_req_cookie(build_conn(), "_kanban_saml_relay", relay_cookie)

      conn =
        acs(ctx.organization.id, %{"SAMLResponse" => response, "RelayState" => relay}, acs_conn)

      assert redirected_to(conn) == "/boards/42"
    end

    test "a replayed assertion is rejected and audited", ctx do
      {conn, params} = sign_in(ctx)
      assert redirected_to(conn) == ~p"/boards"

      replay = acs(ctx.organization.id, params)
      assert redirected_to(replay) == ~p"/users/log-in"
      assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ @refused
      refute get_session(replay, :user_token)

      assert [event] = AuditLog.list_events(action: "saml_assertion_replayed")
      assert event.organization_id == ctx.organization.id
      assert refusal_reasons() == ["assertion_replayed"]
    end

    test "a second assertion for an answered request is rejected", ctx do
      {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)

      response = fn ->
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@#{ctx.domain}"
        )
      end

      first =
        acs(
          ctx.organization.id,
          %{"SAMLResponse" => response.(), "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(first) == ~p"/boards"

      second =
        acs(
          ctx.organization.id,
          %{"SAMLResponse" => response.(), "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(second) == ~p"/users/log-in"
      assert refusal_reasons() == ["request_used"]
    end

    test "an IdP-initiated response with no stored request is rejected", ctx do
      response =
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          email: "pat@#{ctx.domain}"
        )

      conn = acs(ctx.organization.id, %{"SAMLResponse" => response})
      assert redirected_to(conn) == ~p"/users/log-in"

      conn = acs(ctx.organization.id, %{"SAMLResponse" => response, "RelayState" => "unknown"})
      assert redirected_to(conn) == ~p"/users/log-in"

      assert refusal_reasons() == ["missing_request", "missing_request"]
      refute Accounts.get_user_by_email("pat@#{ctx.domain}")
    end

    test "an expired request is rejected", ctx do
      {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)

      Repo.get_by!(Request, relay_token: relay)
      |> Ecto.Changeset.change(expires_at: :second |> DateTime.utc_now() |> DateTime.add(-1))
      |> Repo.update!()

      response =
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@#{ctx.domain}"
        )

      conn =
        acs(
          ctx.organization.id,
          %{"SAMLResponse" => response, "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(conn) == ~p"/users/log-in"
      assert refusal_reasons() == ["request_expired"]
    end

    test "an email on a domain the Organization has not verified is refused", ctx do
      {conn, _params} = sign_in(ctx, email: "pat@unverified.example")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      refute Accounts.get_user_by_email("pat@unverified.example")
      assert refusal_reasons() == ["domain_not_verified"]
    end

    test "a user in another Organization is refused and audited", ctx do
      other = organization_fixture()
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      organization_member_fixture(other, user)

      {conn, _params} = sign_in(ctx)

      assert redirected_to(conn) == ~p"/users/log-in"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert flash =~ @refused
      refute flash =~ other.name
      assert Organizations.get_membership(user).organization_id == other.id
      assert refusal_reasons() == ["membership_conflict"]
    end

    test "a disabled user cannot sign in", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      user |> Accounts.User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      {conn, _params} = sign_in(ctx)
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert refusal_reasons() == ["user_disabled"]
    end

    test "an assertion for one Organization never provisions into another", ctx do
      other = organization_fixture()
      verified_domain_fixture(other, "other-#{ctx.domain}")
      saml_connection_fixture(other, ctx.idp.pem)

      {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)

      response =
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@other-#{ctx.domain}"
        )

      conn =
        acs(other.id, %{"SAMLResponse" => response, "RelayState" => relay}, browser(start_conn))

      assert redirected_to(conn) == ~p"/users/log-in"
      refute Accounts.get_user_by_email("pat@other-#{ctx.domain}")
      assert refusal_reasons() == ["missing_request"]

      # Posted to the right Organization, the email is still not on its domain.
      conn =
        acs(
          ctx.organization.id,
          %{"SAMLResponse" => response, "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(conn) == ~p"/users/log-in"
      refute Accounts.get_user_by_email("pat@other-#{ctx.domain}")
    end

    test "a disabled connection or an unknown Organization is refused", ctx do
      {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)
      ctx.connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

      response =
        SAMLTestHelpers.response(ctx.idp,
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@#{ctx.domain}"
        )

      conn =
        acs(
          ctx.organization.id,
          %{"SAMLResponse" => response, "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(conn) == ~p"/users/log-in"

      conn =
        acs(
          "not-a-number",
          %{"SAMLResponse" => response, "RelayState" => relay},
          browser(start_conn)
        )

      assert redirected_to(conn) == ~p"/users/log-in"

      assert refusal_reasons() == ["connection_unavailable", "connection_unavailable"]
    end

    test "a tampered response is refused with the generic message", ctx do
      {start_conn, relay, request_id, _location} = start(build_conn(), ctx.domain)

      xml =
        ctx.idp
        |> SAMLTestHelpers.raw_response(
          organization_id: ctx.organization.id,
          request_id: request_id,
          email: "pat@#{ctx.domain}"
        )
        |> String.replace("pat@", "boss@")

      conn =
        acs(
          ctx.organization.id,
          %{
            "SAMLResponse" => SAMLTestHelpers.encode(xml),
            "RelayState" => relay
          },
          browser(start_conn)
        )

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      assert refusal_reasons() == ["signature_invalid"]
    end
  end

  describe "GET /org/sso/saml/metadata" do
    test "an org-admin downloads the SP metadata of their Organization", ctx do
      admin = user_fixture()
      organization_member_fixture(ctx.organization, admin, :org_admin)

      conn = build_conn() |> log_in_user(admin) |> get(~p"/org/sso/saml/metadata")

      assert response(conn, 200) =~ "/users/sso/saml/#{ctx.organization.id}/acs"
      assert response_content_type(conn, :xml) =~ "application/samlmetadata+xml"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
    end

    test "a member who is not an org-admin is refused", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      conn = build_conn() |> log_in_user(member) |> get(~p"/org/sso/saml/metadata")
      assert redirected_to(conn) =~ "/"
      refute conn.resp_body =~ "EntityDescriptor"
    end
  end

  # The SAML paid gate is SSO.check_access/2, as for OIDC. Its refusal branch
  # cannot be reached here: Kanban.Plans gives paid access to any
  # Organization member, provisioning makes the user a member before the
  # gate runs, and the metadata route needs an org-admin. These tests pin the
  # gate's wiring with enforcement on: a member passes it on both routes.
  describe "with paid plans enforced" do
    setup :enforce_plans

    test "a SAML sign-in passes the paid gate and writes the SSO session marker", ctx do
      {conn, _params} = sign_in(ctx)

      assert redirected_to(conn) == ~p"/boards"

      assert get_session(conn, OrganizationTwoFactorGate.sso_session_key()) ==
               ctx.organization.id

      assert refusal_reasons() == []
    end

    test "an org-admin downloads the SP metadata", ctx do
      admin = user_fixture()
      organization_member_fixture(ctx.organization, admin, :org_admin)

      conn = build_conn() |> log_in_user(admin) |> get(~p"/org/sso/saml/metadata")
      assert response(conn, 200) =~ "EntityDescriptor"
    end
  end

  describe "rate limiting" do
    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        sso: %{scale_ms: 60_000, ip_limit: 1}
      )

      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      %{ip: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}}
    end

    test "the assertion consumer service is throttled per IP", ctx do
      conn =
        acs(ctx.organization.id, %{"SAMLResponse" => "x"}, %{build_conn() | remote_ip: ctx.ip})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused

      conn =
        acs(ctx.organization.id, %{"SAMLResponse" => "x"}, %{build_conn() | remote_ip: ctx.ip})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    end
  end
end
