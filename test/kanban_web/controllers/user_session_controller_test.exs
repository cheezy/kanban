defmodule KanbanWeb.UserSessionControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/register" do
    test "registers the user, sends a confirmation email, and does not log them in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"

      user = Kanban.Repo.get_by!(Kanban.Accounts.User, email: email)

      assert Kanban.Repo.get_by!(Kanban.Accounts.UserToken,
               user_id: user.id,
               context: "confirm"
             )
    end

    test "returns error flash with invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => "invalid", "password" => "short"}
        })

      assert redirected_to(conn) == ~p"/users/register"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "An error occurred during registration"
    end
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/boards"

      conn = get(conn, ~p"/boards")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_kanban_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/boards"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "refuses a disabled user holding valid credentials", %{conn: conn, user: user} do
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    # The refusal must be indistinguishable from a wrong password, or it
    # discloses that the address belongs to a real, disabled account.
    test "refuses a disabled user with the same response as a wrong password", %{user: user} do
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      disabled_conn =
        post(build_conn(), ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      unknown_conn =
        post(build_conn(), ~p"/users/log-in?mode=password", %{
          "user" => %{
            "email" => "unknown#{System.unique_integer()}@example.com",
            "password" => valid_user_password()
          }
        })

      assert Phoenix.Flash.get(disabled_conn.assigns.flash, :error) ==
               Phoenix.Flash.get(unknown_conn.assigns.flash, :error)

      assert redirected_to(disabled_conn) == redirected_to(unknown_conn)
      refute get_session(disabled_conn, :user_token)
    end

    # Pins the precedence: the disabled refusal must win over the unconfirmed
    # branch, which redirects to a distinct page and so discloses the account.
    test "refuses a user who is both unconfirmed and disabled without disclosing them", %{
      conn: conn,
      unconfirmed_user: unconfirmed_user
    } do
      {:ok, _} = Accounts.disable_user(unconfirmed_user, admin_fixture())

      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => unconfirmed_user.email, "password" => valid_user_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "logs in a user again once they are re-enabled", %{conn: conn, user: user} do
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Accounts.enable_user(disabled)

      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/boards"
    end

    test "redirects to login page with an unknown email", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => "unknown#{System.unique_integer()}@example.com",
            "password" => valid_user_password()
          }
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "redirects an unconfirmed user with valid credentials to the confirmation-pending page",
         %{
           conn: conn,
           unconfirmed_user: unconfirmed_user
         } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => unconfirmed_user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)

      assert redirected_to(conn) ==
               ~p"/users/confirmation-pending?email=#{unconfirmed_user.email}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "confirm your account before signing in"
    end

    test "URL-encodes an unconfirmed email containing a plus sign in the redirect", %{conn: conn} do
      email = "user+tag#{System.unique_integer()}@example.com"
      unconfirmed_user_fixture(email: email)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"
      assert redirected_to(conn) =~ "%2B"
    end

    test "renders the unconfirmed denial message on the confirmation-pending page", %{
      conn: conn,
      unconfirmed_user: unconfirmed_user
    } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => unconfirmed_user.email, "password" => valid_user_password()}
        })

      conn = get(conn, redirected_to(conn))
      response = html_response(conn, 200)

      assert response =~ "You must confirm your account before signing in."
      assert response =~ "Resend confirmation email"
    end

    test "renders the invalid-credentials message on the login page", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      conn = get(conn, ~p"/users/log-in")
      assert html_response(conn, 200) =~ "Invalid email or password"
    end

    test "does not issue a remember-me cookie for an unconfirmed user", %{
      conn: conn,
      unconfirmed_user: unconfirmed_user
    } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => unconfirmed_user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      refute conn.resp_cookies["_kanban_web_user_remember_me"]
      refute get_session(conn, :user_token)
    end

    test "does not log in an unconfirmed user via the _action confirmed path", %{
      conn: conn,
      unconfirmed_user: unconfirmed_user
    } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "_action" => "confirmed",
          "user" => %{"email" => unconfirmed_user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)

      assert redirected_to(conn) ==
               ~p"/users/confirmation-pending?email=#{unconfirmed_user.email}"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "confirm your account before signing in"
    end

    test "logs in a confirmed user via the _action confirmed path", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "_action" => "confirmed",
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
