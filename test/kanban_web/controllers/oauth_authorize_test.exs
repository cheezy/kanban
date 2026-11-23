defmodule KanbanWeb.OAuthAuthorizeTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.DeviceToken
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  @redirect_uri "com.stridelikeaboss.app:/oauth/callback"

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => "stride-ios",
        "redirect_uri" => @redirect_uri,
        "code_challenge" => valid_code_challenge(),
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "device_name" => "iPhone 15",
        "device_class" => "phone"
      },
      overrides
    )
  end

  defp authorize_path(params), do: "/oauth/authorize?" <> URI.encode_query(params)

  defp code_count, do: Repo.aggregate(AuthorizationCode, :count)

  defp callback_query(conn) do
    location = redirected_to(conn)
    uri = URI.parse(location)

    assert uri.scheme == "com.stridelikeaboss.app"
    assert uri.path == "/oauth/callback"
    assert "#{uri.scheme}:#{uri.path}" == @redirect_uri

    URI.decode_query(uri.query)
  end

  describe "GET /oauth/authorize, signed in" do
    setup :register_and_log_in_user

    test "a signed-in person sees the confirmation page naming the device", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, authorize_path(valid_params()))
      html = html_response(conn, 200)

      assert html =~ "Sign in to Stride on iPhone 15?"
      assert html =~ user.email
      doc = LazyHTML.from_document(html)
      form = LazyHTML.query(doc, ~s(form#oauth-authorize-form[method="post"]))
      assert LazyHTML.attribute(form, "action") == ["/oauth/authorize"]

      for selector <- [
            ~s(button[type="submit"][name="decision"][value="allow"]),
            ~s(button[type="submit"][name="decision"][value="cancel"]),
            ~s(input[type="hidden"][name="state"][value="xyz"]),
            ~s(input[type="hidden"][name="code_challenge_method"][value="S256"]),
            ~s(input[type="hidden"][name="_csrf_token"])
          ] do
        refute form |> LazyHTML.query(selector) |> Enum.empty?(), selector
      end

      # Showing the page never issues a code: the confirmation is the protection.
      assert code_count() == 0
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "the page's policy lets its form redirect to the app and keeps the nonce", %{
      conn: conn
    } do
      conn = get(conn, authorize_path(valid_params()))
      [policy] = get_resp_header(conn, "content-security-policy")

      assert policy =~ "form-action 'self' com.stridelikeaboss.app:;"
      assert policy =~ "script-src 'self' 'nonce-#{conn.assigns.csp_nonce}'"
      assert policy =~ "frame-ancestors 'self'"
    end

    test "other pages keep form-action 'self' alone", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      [policy] = get_resp_header(conn, "content-security-policy")

      assert policy =~ "form-action 'self';"
      refute policy =~ "com.stridelikeaboss.app"
    end

    test "a tablet hint shows the tablet icon", %{conn: conn} do
      html =
        conn
        |> get(authorize_path(valid_params(%{"device_class" => "tablet"})))
        |> html_response(200)

      assert html =~ "hero-device-tablet"
    end

    test "device_name with markup is shown as text", %{conn: conn} do
      params = valid_params(%{"device_name" => ~S|<script>alert("x")</script>|})
      html = conn |> get(authorize_path(params)) |> html_response(200)

      assert html =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
      refute html =~ "<script>alert"
    end

    test "renders the page in German", %{conn: conn} do
      html =
        conn
        |> Plug.Conn.put_session(:locale, "de")
        |> get(authorize_path(valid_params()))
        |> html_response(200)

      assert html =~ "Bei Stride auf iPhone 15 anmelden?"
      assert html =~ "Erlauben"
      assert html =~ "Abbrechen"
    end

    test "a long German device name wraps and leaves both buttons in place", %{conn: conn} do
      name = String.duplicate("Donaudampfschifffahrtsgesellschaftskapitän", 6)
      assert String.length(name) <= 255

      doc =
        conn
        |> Plug.Conn.put_session(:locale, "de")
        |> get(authorize_path(valid_params(%{"device_name" => name})))
        |> html_response(200)
        |> LazyHTML.from_document()

      [style] = doc |> LazyHTML.query("#oauth-authorize-title") |> LazyHTML.attribute("style")
      assert style =~ "overflow-wrap: anywhere"
      assert doc |> LazyHTML.query("#oauth-authorize-title") |> LazyHTML.text() =~ name

      for decision <- ["allow", "cancel"] do
        button = LazyHTML.query(doc, ~s(#oauth-authorize-form button[value="#{decision}"]))
        refute Enum.empty?(button), decision
        assert [_style] = LazyHTML.attribute(button, "style")
        assert hd(LazyHTML.attribute(button, "style")) =~ "width: 100%"
      end
    end
  end

  describe "POST /oauth/authorize" do
    setup :register_and_log_in_user

    test "Allow redirects to the app with a code and the same state", %{conn: conn, user: user} do
      before = DateTime.utc_now(:second)
      conn = post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))

      query = callback_query(conn)
      assert Map.keys(query) |> Enum.sort() == ["code", "state"]
      assert query["state"] == "xyz"
      assert "sdac_" <> _rest = code = query["code"]

      stored = Repo.get_by!(AuthorizationCode, code_hash: DeviceToken.hash_token(code))
      assert stored.user_id == user.id
      assert stored.client_id == "stride-ios"
      assert stored.redirect_uri == @redirect_uri
      assert stored.code_challenge == valid_code_challenge()
      assert stored.device_name == "iPhone 15"
      assert is_nil(stored.used_at)
      assert DateTime.diff(stored.expires_at, stored.inserted_at) == 60
      assert DateTime.compare(stored.inserted_at, before) in [:gt, :eq]
      # Only the hash is stored.
      refute from(c in AuthorizationCode, where: c.code_hash == ^code) |> Repo.exists?()
      assert code_count() == 1
    end

    test "a state with spaces and reserved characters comes back unchanged", %{conn: conn} do
      state = "a b&c=d+e/?%"
      params = valid_params(%{"state" => state, "decision" => "allow"})

      conn = post(conn, ~p"/oauth/authorize", params)

      assert redirected_to(conn) =~ "state=a%20b%26c%3Dd%2Be%2F%3F%25"
      assert callback_query(conn)["state"] == state
    end

    test "Cancel redirects with error=access_denied and no code", %{conn: conn} do
      conn = post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "cancel"))

      query = callback_query(conn)
      assert query == %{"error" => "access_denied", "state" => "xyz"}
      assert code_count() == 0
    end

    test "an unknown or missing decision is refused", %{conn: conn} do
      for params <- [Map.put(valid_params(), "decision", "maybe"), valid_params()] do
        conn = post(conn, ~p"/oauth/authorize", params)

        assert html_response(conn, 400) =~ "This sign-in request isn&#39;t valid"
        assert get_resp_header(conn, "location") == []
      end

      assert code_count() == 0
    end

    test "Allow is a CSRF-protected POST and never a GET", %{conn: conn} do
      route = Phoenix.Router.route_info(KanbanWeb.Router, "POST", "/oauth/authorize", "")
      assert :browser in route.pipe_through
      assert route.plug_opts == :confirm

      # Without a CSRF token :protect_from_forgery raises before the
      # controller runs; the endpoint renders the error and Phoenix re-raises
      # it in tests, so the test pins the exception itself.
      csrf_conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(csrf_conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))
      end

      # A GET carrying decision=allow only shows the page again.
      conn =
        get(conn, authorize_path(Map.put(valid_params(), "decision", "allow")))

      assert html_response(conn, 200) =~ "Sign in to Stride on iPhone 15?"
      assert code_count() == 0
    end
  end

  describe "invalid requests" do
    setup :register_and_log_in_user

    @invalid [
      {"missing state", %{"state" => nil}},
      {"empty state", %{"state" => ""}},
      {"a state with a control character", %{"state" => "a\nb"}},
      {"a plain challenge method", %{"code_challenge_method" => "plain"}},
      {"a missing challenge method", %{"code_challenge_method" => nil}},
      {"a malformed challenge", %{"code_challenge" => "short"}},
      {"a wrong redirect URI", %{"redirect_uri" => "https://evil.test/callback"}},
      {"a redirect URI with a trailing slash", %{"redirect_uri" => @redirect_uri <> "/"}},
      {"a missing redirect URI", %{"redirect_uri" => nil}},
      {"an unknown client", %{"client_id" => "stride-web"}},
      {"a missing device name", %{"device_name" => nil}},
      {"a blank device name", %{"device_name" => "   "}},
      {"a device name over 255 characters", %{"device_name" => String.duplicate("a", 256)}},
      {"an unknown device class", %{"device_class" => "watch"}},
      {"a missing device class", %{"device_class" => nil}},
      {"another response type", %{"response_type" => "token"}}
    ]

    test "refuses a missing state, a plain challenge method or a wrong redirect URI", %{
      conn: conn
    } do
      for {label, override} <- @invalid do
        params = valid_params() |> Map.merge(override) |> Map.reject(fn {_k, v} -> is_nil(v) end)

        get_conn = get(conn, authorize_path(params))
        assert html_response(get_conn, 400) =~ "This sign-in request isn&#39;t valid", label
        assert get_resp_header(get_conn, "location") == [], label

        for decision <- ["allow", "cancel"] do
          post_conn = post(conn, ~p"/oauth/authorize", Map.put(params, "decision", decision))
          assert html_response(post_conn, 400) =~ "isn&#39;t valid", "#{label} (#{decision})"
          assert get_resp_header(post_conn, "location") == [], "#{label} (#{decision})"
        end
      end

      assert code_count() == 0
    end

    test "a repeated parameter is refused rather than crashing", %{conn: conn} do
      for key <- ~w(client_id redirect_uri code_challenge code_challenge_method state
                    device_name device_class) do
        query = valid_params() |> Map.delete(key) |> URI.encode_query()
        query = query <> "&#{key}[]=a&#{key}[]=b"

        conn = get(conn, "/oauth/authorize?" <> query)
        assert html_response(conn, 400) =~ "isn&#39;t valid", key
      end
    end

    test "a parameter named twice is refused, not read as its last value", %{conn: conn} do
      for key <- ~w(client_id redirect_uri code_challenge code_challenge_method state
                    device_name device_class response_type) do
        value = Map.fetch!(valid_params(), key)
        query = URI.encode_query(valid_params()) <> "&" <> URI.encode_query(%{key => value})

        conn = get(conn, "/oauth/authorize?" <> query)
        assert html_response(conn, 400) =~ "isn&#39;t valid", key
        assert get_resp_header(conn, "location") == [], key
      end

      # A parameter outside the request, such as a tracking tag, may repeat.
      conn = get(conn, authorize_path(valid_params()) <> "&utm=a&utm=b")
      assert html_response(conn, 200) =~ "Sign in to Stride on iPhone 15?"
    end

    test "a device name that could read as another name is refused", %{conn: conn} do
      for name <- [
            "Pixel\u202E9 lexiP",
            "iPhone\u2066 15\u2069",
            "Line one\nLine two",
            "Tab\there",
            "Mark\u200Fed"
          ] do
        conn = get(conn, authorize_path(valid_params(%{"device_name" => name})))
        assert html_response(conn, 400) =~ "isn&#39;t valid", inspect(name)

        conn =
          post(
            conn,
            ~p"/oauth/authorize",
            valid_params(%{"device_name" => name, "decision" => "allow"})
          )

        assert html_response(conn, 400) =~ "isn&#39;t valid", inspect(name)
      end

      assert code_count() == 0
    end

    test "a confirm POST with fields in its URL is refused", %{conn: conn} do
      for {query, body} <- [
            {"decision=allow", valid_params()},
            {URI.encode_query(%{"state" => "other"}),
             Map.put(valid_params(), "decision", "allow")},
            {"x=1", Map.put(valid_params(), "decision", "cancel")}
          ] do
        conn = post(conn, "/oauth/authorize?" <> query, body)

        assert html_response(conn, 400) =~ "isn&#39;t valid", query
        assert get_resp_header(conn, "location") == [], query
      end

      assert code_count() == 0
    end

    test "a redirect target in the query string is ignored", %{conn: conn} do
      params =
        valid_params(%{
          "decision" => "allow",
          "redirect" => "https://evil.test",
          "return_to" => "https://evil.test",
          "redirect_to" => "https://evil.test"
        })

      conn = post(conn, ~p"/oauth/authorize", params)

      assert conn |> redirected_to() |> String.starts_with?(@redirect_uri <> "?")
    end
  end

  describe "signed out" do
    test "A signed-out GET /oauth/authorize redirect carries cache-control no-store", %{
      conn: conn
    } do
      conn = get(conn, authorize_path(valid_params()))

      assert redirected_to(conn) == ~p"/users/log-in"
      # Set before the log-in gate halts (D463), not Plug's default
      # "max-age=0, private, must-revalidate".
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a signed-out HEAD /oauth/authorize redirect carries no-store", %{conn: conn} do
      conn = head(conn, authorize_path(valid_params()))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a signed-out visitor is sent to log in and comes back to the page", %{conn: conn} do
      path = authorize_path(valid_params())
      conn = get(conn, path)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == path

      user = user_fixture() |> set_password()

      conn =
        conn
        |> recycle()
        |> init_test_session(user_return_to: path)
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == path
    end

    test "a request too long to come back to after signing in is a 400, not a 500", %{
      conn: conn
    } do
      # A valid request: a 255-character Japanese device name and a 255-character
      # state percent-encode to more than the session cookie can carry back.
      params =
        valid_params(%{
          "device_name" => String.duplicate("日", 255),
          "state" => String.duplicate("%", 255)
        })

      conn = get(conn, authorize_path(params))

      html = html_response(conn, 400)
      assert html =~ "This sign-in request isn&#39;t valid"
      assert get_session(conn, :user_return_to) == nil
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      assert get_resp_header(conn, "set-cookie")
             |> Enum.map(&byte_size/1)
             |> Enum.all?(&(&1 <= 4096))

      assert code_count() == 0
    end

    test "a signed-in person may send the same long request", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      params =
        valid_params(%{
          "device_name" => String.duplicate("日", 255),
          "state" => String.duplicate("%", 255)
        })

      assert conn |> get(authorize_path(params)) |> html_response(200) =~ "日日日"
    end

    test "the session expiring before Allow issues no code", %{conn: conn} do
      conn = post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert code_count() == 0
    end
  end

  describe "Organization two-factor gate" do
    @day 24 * 60 * 60

    setup do
      org = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(org, admin, :org_admin)
      member = user_fixture()
      organization_member_fixture(org, member)
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      past = :second |> DateTime.utc_now() |> DateTime.add(-30 * @day, :second)

      from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      |> Repo.update_all(set: [two_factor_enforced_at: past])

      from(m in OrganizationMember, where: m.organization_id == ^org.id)
      |> Repo.update_all(set: [inserted_at: past])

      %{member: member, org: org}
    end

    defp allow_code(conn) do
      conn = post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))
      code = callback_query(conn)["code"]
      {code, Repo.get_by!(AuthorizationCode, code_hash: DeviceToken.hash_token(code))}
    end

    defp exchange_and_refresh(code) do
      tokens =
        build_conn()
        |> post(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => "stride-ios",
          "code" => code,
          "code_verifier" => valid_code_verifier(),
          "redirect_uri" => @redirect_uri,
          "platform" => "ios",
          "device_class" => "phone",
          "approval_public_key" => valid_approval_public_key()
        })
        |> json_response(200)

      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => "stride-ios",
        "refresh_token" => tokens["refresh_token"]
      })
    end

    test "an overdue member signed in through their Organization's SSO allows a device that keeps refreshing",
         %{conn: conn, member: member, org: org} do
      conn =
        conn
        |> log_in_user(member)
        |> Plug.Conn.put_session(OrganizationTwoFactorGate.sso_session_key(), org.id)

      {code, stored} = allow_code(conn)
      assert stored.sso_organization_id == org.id

      assert %{"access_token" => _} = code |> exchange_and_refresh() |> json_response(200)
    end

    test "an SSO marker in the request params is never recorded", %{conn: conn} do
      # A member of no Organization reaches Allow without any mark.
      user = user_fixture()
      conn = log_in_user(conn, user)

      conn =
        post(
          conn,
          ~p"/oauth/authorize",
          valid_params(%{"decision" => "allow", "sso_authenticated" => "1"})
        )

      code = callback_query(conn)["code"]
      stored = Repo.get_by!(AuthorizationCode, code_hash: DeviceToken.hash_token(code))
      assert stored.sso_organization_id == nil
    end

    test "a password sign-in before the deadline allows a device refused once it passes", %{
      conn: conn,
      member: member,
      org: org
    } do
      # Back in grace: the requirement started just now.
      now = DateTime.utc_now(:second)

      from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      |> Repo.update_all(set: [two_factor_enforced_at: now])

      from(m in OrganizationMember, where: m.organization_id == ^org.id)
      |> Repo.update_all(set: [inserted_at: now])

      {code, stored} = conn |> log_in_user(member) |> allow_code()
      assert stored.sso_organization_id == nil

      tokens =
        build_conn()
        |> post(~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => "stride-ios",
          "code" => code,
          "code_verifier" => valid_code_verifier(),
          "redirect_uri" => @redirect_uri,
          "platform" => "ios",
          "device_class" => "phone",
          "approval_public_key" => valid_approval_public_key()
        })
        |> json_response(200)

      # The grace period ends.
      past = DateTime.add(now, -30 * @day, :second)

      from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      |> Repo.update_all(set: [two_factor_enforced_at: past])

      from(m in OrganizationMember, where: m.organization_id == ^org.id)
      |> Repo.update_all(set: [inserted_at: past])

      assert %{"error" => "invalid_grant"} =
               build_conn()
               |> post(~p"/oauth/token", %{
                 "grant_type" => "refresh_token",
                 "client_id" => "stride-ios",
                 "refresh_token" => tokens["refresh_token"]
               })
               |> json_response(400)
    end

    test "an Organization member overdue on two-factor is sent to enroll", %{
      conn: conn,
      member: member
    } do
      conn = log_in_user(conn, member)

      get_conn = get(conn, authorize_path(valid_params()))
      assert redirected_to(get_conn) == "/users/settings?section=two_factor"

      post_conn =
        post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))

      assert redirected_to(post_conn) == "/users/settings?section=two_factor"
      assert code_count() == 0
    end

    test "The organization two-factor gate redirect on /oauth/authorize carries no-store", %{
      conn: conn,
      member: member
    } do
      conn = log_in_user(conn, member)

      get_conn = get(conn, authorize_path(valid_params()))
      assert redirected_to(get_conn) == "/users/settings?section=two_factor"
      assert get_resp_header(get_conn, "cache-control") == ["no-store"]

      post_conn =
        post(conn, ~p"/oauth/authorize", Map.put(valid_params(), "decision", "allow"))

      assert redirected_to(post_conn) == "/users/settings?section=two_factor"
      assert get_resp_header(post_conn, "cache-control") == ["no-store"]
    end
  end

  describe "answers given before the router reaches the controller (D463)" do
    test "PUT /oauth/authorize answers with no-store", %{conn: conn} do
      conn = put(conn, ~p"/oauth/authorize", valid_params())

      assert conn.status == 404
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "every other wrong verb and unrouted path there answers with no-store" do
      for {label, request} <- [
            {"DELETE", &delete(&1, "/oauth/authorize")},
            {"a _method=put override", &post(&1, "/oauth/authorize", %{"_method" => "put"})},
            {"an unrouted path under it", &get(&1, "/oauth/authorize/extra")}
          ] do
        conn = request.(build_conn())

        assert conn.status == 404, label
        assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"], label
        assert get_resp_header(conn, "cache-control") == ["no-store"], label
      end
    end

    test "a malformed query string answers its HTML 400 with no-store" do
      {400, headers, body} =
        assert_error_sent(400, fn -> get(build_conn(), "/oauth/authorize?a=%FF") end)

      assert {"cache-control", "no-store"} in headers
      assert {"content-type", "text/html; charset=utf-8"} in headers
      assert body =~ "<!DOCTYPE html>"
    end

    test "a malformed query string asked for as JSON answers a JSON 400 with no-store" do
      {400, headers, body} =
        assert_error_sent(400, fn ->
          build_conn()
          |> put_req_header("accept", "application/json")
          |> get("/oauth/authorize?a=%FF")
        end)

      assert {"cache-control", "no-store"} in headers
      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    test "a signed-in page keeps the controller's own headers", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, authorize_path(valid_params()))

      assert html_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end
end
