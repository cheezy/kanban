defmodule KanbanWeb.OIDCControllerTest.FakeStrategy do
  def authorize_url(_config) do
    {:ok,
     %{
       url: "https://auth.example.com/application/o/authorize/?state=fake",
       session_params: %{"state" => "fake-state", "nonce" => "fake-nonce"}
     }}
  end

  def callback(config, %{"code" => "valid", "state" => "fake-state"}) do
    case Keyword.fetch!(config, :session_params) do
      %{"state" => "fake-state", "nonce" => "fake-nonce"} ->
        {:ok,
         %{
           user: %{
             "sub" => "authentik-user-1",
             "email" => "oidc-user@example.com",
             "email_verified" => true,
             "name" => "OIDC User",
             "groups" => ["stride-admins"]
           }
         }}

      _session_params ->
        {:error, :invalid_session}
    end
  end

  def callback(_config, _params), do: {:error, :invalid_callback}
end

defmodule KanbanWeb.OIDCControllerTest do
  use KanbanWeb.ConnCase, async: false

  alias Kanban.Accounts
  alias Kanban.OIDC

  setup do
    original = Application.get_env(:kanban, :oidc)

    Application.put_env(:kanban, :oidc,
      enabled: true,
      issuer: "https://auth.example.com/application/o/stride/",
      client_id: "stride",
      client_secret: "secret",
      display_name: "Authentik",
      scopes: "openid email profile",
      require_verified_email: true,
      admin_group_claim: "groups",
      admin_groups: ["stride-admins"],
      strategy_module: KanbanWeb.OIDCControllerTest.FakeStrategy
    )

    on_exit(fn -> Application.put_env(:kanban, :oidc, original) end)
  end

  describe "GET /users/sso" do
    test "redirects to the provider and stores OIDC session params", %{conn: conn} do
      conn = get(conn, ~p"/users/sso")

      assert redirected_to(conn) == "https://auth.example.com/application/o/authorize/?state=fake"

      assert get_session(conn, OIDC.session_key()) == %{
               "state" => "fake-state",
               "nonce" => "fake-nonce"
             }
    end

    test "redirects safely when OIDC is disabled", %{conn: conn} do
      Application.put_env(:kanban, :oidc, enabled: false)

      conn = get(conn, ~p"/users/sso")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Single sign-on is not configured."
    end
  end

  describe "GET /users/sso/callback" do
    test "logs in a valid OIDC user and provisions an admin from groups", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{
          OIDC.session_key() => %{"state" => "fake-state", "nonce" => "fake-nonce"}
        })
        |> get(~p"/users/sso/callback?code=valid&state=fake-state")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/boards"

      user = Accounts.get_user_by_email("oidc-user@example.com")
      assert user.name == "OIDC User"
      assert user.confirmed_at
      assert user.type == :admin
    end

    test "honors the existing return-to path after callback", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{
          :user_return_to => "/review",
          OIDC.session_key() => %{"state" => "fake-state", "nonce" => "fake-nonce"}
        })
        |> get(~p"/users/sso/callback?code=valid&state=fake-state")

      assert redirected_to(conn) == "/review"
    end

    test "rejects a callback without stored session params", %{conn: conn} do
      conn = get(conn, ~p"/users/sso/callback?code=valid&state=fake-state")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Single sign-on session expired. Please try again."
    end

    test "redirects safely on provider callback errors", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{
          OIDC.session_key() => %{"state" => "fake-state", "nonce" => "fake-nonce"}
        })
        |> get(~p"/users/sso/callback?code=bad&state=fake-state")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Single sign-on failed. Please try again."
    end
  end
end
