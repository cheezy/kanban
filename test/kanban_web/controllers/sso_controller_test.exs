defmodule KanbanWeb.SSOControllerTest do
  # async: false: the rate limit tests change the global Kanban.RateLimit env.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.Accounts
  alias Kanban.AuditLog
  alias Kanban.OIDCTestHelpers
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  @refused "Single sign-on could not sign you in."

  setup_all do
    %{jwk: OIDCTestHelpers.signing_key()}
  end

  setup do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization).domain
    connection = oidc_connection_fixture(organization)
    %{organization: organization, domain: domain, connection: connection}
  end

  # Starts a sign-in and returns the conn (carrying the session) and the
  # authorization request's query.
  defp start(conn, domain, jwk \\ OIDCTestHelpers.signing_key()) do
    OIDCTestHelpers.stub_idp(jwk, fn _form -> {:status, 400} end)
    conn = get(conn, ~p"/users/sso/start?#{[domain: domain]}")
    location = redirected_to(conn, 302)
    {conn, location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()}
  end

  defp callback(conn, params), do: get(recycle(conn), ~p"/users/sso/callback?#{params}")

  defp sign_in(conn, ctx, claims_overrides) do
    {conn, query} = start(conn, ctx.domain, ctx.jwk)

    OIDCTestHelpers.stub_idp(ctx.jwk, fn _form ->
      OIDCTestHelpers.claims(
        [nonce: query["nonce"], email: "pat@#{ctx.domain}"] ++ claims_overrides
      )
    end)

    {callback(conn, code: "the-code", state: query["state"]), query}
  end

  describe "GET /users/sso/start" do
    test "redirects to the identity provider with PKCE, state and nonce", %{conn: conn} = ctx do
      {conn, query} = start(conn, String.upcase(ctx.domain))

      assert query["code_challenge_method"] == "S256"
      assert query["state"] && query["nonce"] && query["code_challenge"]
      assert query["redirect_uri"] =~ "/users/sso/callback"

      flow = get_session(conn, "sso_flow")
      assert flow["state"] == query["state"]
      assert flow["connection_id"] == ctx.connection.id
    end

    test "a start from another site goes to the log-in page and starts no flow", ctx do
      for site <- ["cross-site", "same-site"] do
        conn =
          build_conn()
          |> put_req_header("sec-fetch-site", site)
          |> get(~p"/users/sso/start?#{[domain: ctx.domain]}")

        assert redirected_to(conn) == ~p"/users/log-in"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "single sign-on"
        refute get_session(conn, "sso_flow")
      end
    end

    test "a start from this site or a typed address goes to the identity provider", ctx do
      for site <- ["same-origin", "none"] do
        {conn, query} = start(put_req_header(build_conn(), "sec-fetch-site", site), ctx.domain)
        assert get_session(conn, "sso_flow")["state"] == query["state"]
      end
    end

    test "a domain with no verified Organization is not available", %{conn: conn} do
      conn = get(conn, ~p"/users/sso/start?domain=unclaimed.example")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
      refute get_session(conn, "sso_flow")

      conn = get(build_conn(), ~p"/users/sso/start")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "an unreachable identity provider gives the same answer", %{conn: conn} = ctx do
      Req.Test.stub(Kanban.SSO.OIDC, &Req.Test.transport_error(&1, :timeout))
      conn = get(conn, ~p"/users/sso/start?#{[domain: ctx.domain]}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
    end
  end

  describe "GET /users/sso/callback" do
    test "signs in a new user, marks the session and lands on /boards", %{conn: conn} = ctx do
      {conn, query} = sign_in(conn, ctx, sub: "new-subject")

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)

      assert get_session(conn, OrganizationTwoFactorGate.sso_session_key()) ==
               ctx.organization.id

      refute get_session(conn, "sso_flow")

      user = Accounts.get_user_by_email("pat@#{ctx.domain}")
      assert user.confirmed_at
      assert Organizations.member?(user, ctx.organization.id)

      assert_received {:token_request, form, _auth}
      assert form["code_verifier"]
      refute form["code_verifier"] == query["code_challenge"]

      assert [event] = AuditLog.list_events(action: "sso_login")
      assert event.organization_id == ctx.organization.id
    end

    test "a second login for the same subject reuses the user even if the email changed",
         %{conn: conn} = ctx do
      {_conn, _query} = sign_in(conn, ctx, sub: "stable-subject")
      first = Accounts.get_user_by_email("pat@#{ctx.domain}")

      {conn, query} = start(build_conn(), ctx.domain)

      OIDCTestHelpers.stub_idp(ctx.jwk, fn _form ->
        OIDCTestHelpers.claims(
          nonce: query["nonce"],
          sub: "stable-subject",
          email: "renamed@other.example"
        )
      end)

      conn = callback(conn, code: "c", state: query["state"])
      assert redirected_to(conn) == ~p"/boards"

      {user, _at} = conn |> get_session(:user_token) |> Accounts.get_user_by_session_token()
      assert user.id == first.id
      refute Accounts.get_user_by_email("renamed@other.example")
    end

    test "a tampered state is rejected and audited", %{conn: conn} = ctx do
      {conn, _query} = start(conn, ctx.domain)
      conn = callback(conn, code: "c", state: "forged")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      refute get_session(conn, :user_token)

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "state_mismatch"
    end

    test "a replayed callback finds no flow and is rejected", %{conn: conn} = ctx do
      {conn, query} = sign_in(conn, ctx, [])
      assert redirected_to(conn) == ~p"/boards"

      replay = callback(conn, code: "the-code", state: query["state"])
      assert redirected_to(replay) == ~p"/users/log-in"

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "missing_flow"
    end

    test "a refused callback still uses up the flow", %{conn: conn} = ctx do
      {conn, query} = start(conn, ctx.domain, ctx.jwk)
      conn = callback(conn, code: "c", state: "forged")
      assert redirected_to(conn) == ~p"/users/log-in"

      OIDCTestHelpers.stub_idp(ctx.jwk, fn _form ->
        OIDCTestHelpers.claims(nonce: query["nonce"], email: "pat@#{ctx.domain}")
      end)

      retry = callback(conn, code: "c", state: query["state"])
      assert redirected_to(retry) == ~p"/users/log-in"
      refute get_session(retry, :user_token)

      reasons =
        AuditLog.list_events(action: "sso_login_refused") |> Enum.map(& &1.metadata["reason"])

      assert Enum.sort(reasons) == ["missing_flow", "state_mismatch"]
    end

    test "a callback without a started flow is rejected", %{conn: conn} do
      conn = get(conn, ~p"/users/sso/callback?code=c&state=s")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "missing_flow"
      assert is_nil(event.metadata["sso_connection_id"])
    end

    test "an expired flow is rejected", %{conn: conn} = ctx do
      {conn, query} = start(conn, ctx.domain)
      flow = get_session(conn, "sso_flow")

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          "sso_flow" => %{flow | "issued_at" => flow["issued_at"] - 601}
        })
        |> get(~p"/users/sso/callback?#{[code: "c", state: query["state"]]}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "flow_expired"
    end

    test "an identity provider error and a missing code are rejected", %{conn: conn} = ctx do
      {conn, query} = start(conn, ctx.domain)
      conn = callback(conn, error: "access_denied", state: query["state"])
      assert redirected_to(conn) == ~p"/users/log-in"

      {conn, query} = start(build_conn(), ctx.domain)
      conn = callback(conn, state: query["state"])
      assert redirected_to(conn) == ~p"/users/log-in"

      reasons =
        AuditLog.list_events(action: "sso_login_refused") |> Enum.map(& &1.metadata["reason"])

      assert Enum.sort(reasons) == ["idp_error", "missing_code"]
    end

    test "a bad nonce is rejected", %{conn: conn} = ctx do
      {conn, query} = start(conn, ctx.domain)

      OIDCTestHelpers.stub_idp(ctx.jwk, fn _form ->
        OIDCTestHelpers.claims(nonce: "wrong", email: "pat@#{ctx.domain}")
      end)

      conn = callback(conn, code: "c", state: query["state"])
      assert redirected_to(conn) == ~p"/users/log-in"

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "invalid_token"
      assert event.organization_id == ctx.organization.id
    end

    test "a user in another Organization gets the generic message and nothing changes",
         %{conn: conn} = ctx do
      other = organization_fixture()
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      organization_member_fixture(other, user)

      {conn, _query} = sign_in(conn, ctx, [])

      assert redirected_to(conn) == ~p"/users/log-in"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert flash =~ @refused
      refute flash =~ other.name

      assert %OrganizationMember{organization_id: other_id} = Organizations.get_membership(user)
      assert other_id == other.id

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "membership_conflict"
    end

    test "a disabled user cannot sign in", %{conn: conn} = ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      user |> Kanban.Accounts.User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      {conn, _query} = sign_in(conn, ctx, [])
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "a connection disabled after the flow started refuses the callback",
         %{conn: conn} = ctx do
      {conn, query} = start(conn, ctx.domain)
      ctx.connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

      conn = callback(conn, code: "c", state: query["state"])
      assert redirected_to(conn) == ~p"/users/log-in"

      assert [event] = AuditLog.list_events(action: "sso_login_refused")
      assert event.metadata["reason"] == "connection_unavailable"
    end

    test "turning a connection off keeps existing sessions and stops new sign-ins",
         %{conn: conn} = ctx do
      {conn, _query} = sign_in(conn, ctx, sub: "kept-subject")
      assert redirected_to(conn) == ~p"/boards"

      ctx.connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

      boards = get(recycle(conn), ~p"/boards")
      assert html_response(boards, 200)

      refused = get(build_conn(), ~p"/users/sso/start?#{[domain: ctx.domain]}")
      assert redirected_to(refused) == ~p"/users/log-in"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "not available"
      refute get_session(refused, "sso_flow")
    end

    test "an SSO session satisfies an overdue two-factor requirement", %{conn: conn} = ctx do
      admin = user_fixture()
      organization_member_fixture(ctx.organization, admin, :org_admin)
      {:ok, _policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      past = :second |> DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

      from(p in SecurityPolicy, where: p.organization_id == ^ctx.organization.id)
      |> Repo.update_all(set: [two_factor_enforced_at: past])

      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      organization_member_fixture(ctx.organization, user)

      from(m in OrganizationMember, where: m.user_id == ^user.id)
      |> Repo.update_all(set: [inserted_at: past])

      {conn, _query} = sign_in(conn, ctx, [])
      assert redirected_to(conn) == ~p"/boards"

      conn = get(recycle(conn), ~p"/boards")
      assert html_response(conn, 200)

      # The same overdue member signed in with a password is redirected.
      password_conn = build_conn() |> log_in_user(user) |> get(~p"/boards")
      assert redirected_to(password_conn) == OrganizationTwoFactorGate.redirect_path()
    end
  end

  describe "rate limiting" do
    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        sso: %{scale_ms: 60_000, ip_limit: 2}
      )

      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      %{ip: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}}
    end

    test "start and callback are throttled per IP", %{conn: conn, ip: ip} do
      for _attempt <- 1..2 do
        conn = get(%{conn | remote_ip: ip}, ~p"/users/sso/start?domain=unclaimed.example")
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
      end

      conn = get(%{build_conn() | remote_ip: ip}, ~p"/users/sso/start?domain=unclaimed.example")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"

      conn = get(%{build_conn() | remote_ip: ip}, ~p"/users/sso/callback?code=c&state=s")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    end
  end
end
