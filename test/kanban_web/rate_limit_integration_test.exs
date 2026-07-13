defmodule KanbanWeb.RateLimitIntegrationTest do
  @moduledoc """
  End-to-end wiring tests for the Hammer-backed rate limiter across the four
  authentication surfaces (login, password reset, confirmation resend, API
  token auth). The limiter is disabled in the broad suite (config/test.exs);
  this module is async: false and enables it with small, known limits so it can
  drive each surface past its threshold without cross-test interference.
  """
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      login: %{scale_ms: 300_000, id_limit: 2, ip_limit: 100},
      reset: %{scale_ms: 900_000, id_limit: 2, ip_limit: 100},
      resend: %{scale_ms: 900_000, id_limit: 2, ip_limit: 100},
      api_token: %{scale_ms: 60_000, ip_limit: 2}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)
    :ok
  end

  # Give each test a distinct client IP so the shared ETS buckets (all requests
  # otherwise arrive from 127.0.0.1) do not bleed between tests in this module.
  defp with_ip(conn) do
    %{conn | remote_ip: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}}
  end

  describe "login (controller)" do
    test "throttles after repeated invalid-credential attempts", %{conn: conn} do
      conn = with_ip(conn)
      email = unique_user_email()

      # id_limit is 2 failures; the 3rd attempt should be throttled.
      for _ <- 1..2 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong-password"}
        })
      end

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong-password"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    end

    test "a valid login is unaffected by another email's failures", %{conn: conn} do
      conn = with_ip(conn)
      user = user_fixture()

      # Burn a different email's budget.
      for _ <- 1..3 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => unique_user_email(), "password" => "wrong"}
        })
      end

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end
  end

  describe "password reset (LiveView)" do
    test "throttles repeated reset requests for the same email", %{conn: conn} do
      email = unique_user_email()

      # First 2 requests are allowed (each redirects to "/" with the neutral flash).
      for _ <- 1..2 do
        {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

        lv
        |> form("#reset_password_form", user: %{email: email})
        |> render_submit()

        assert {"/", flash} = assert_redirect(lv)
        assert flash["info"] =~ "If your email is in our system"
      end

      # The 3rd is throttled — redirects to "/" with the throttle flash.
      {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

      lv
      |> form("#reset_password_form", user: %{email: email})
      |> render_submit()

      assert {"/", flash} = assert_redirect(lv)
      assert flash["info"] =~ "Too many requests"
    end
  end

  describe "confirmation resend (LiveView)" do
    @tag :capture_log
    test "throttles repeated resends for the same email and stops issuing tokens", %{conn: conn} do
      user = unconfirmed_user_fixture()

      for _ <- 1..2 do
        {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")
        lv |> element("button", "Resend confirmation email") |> render_click()
      end

      {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")
      lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(lv) =~ "Too many requests"

      tokens =
        Kanban.Accounts.UserToken
        |> Kanban.Repo.all()
        |> Enum.filter(&(&1.user_id == user.id and &1.context == "confirm"))

      # Only the 2 allowed resends issued tokens; the throttled 3rd did not.
      assert length(tokens) == 2
    end
  end

  describe "API token plug" do
    test "returns 429 after repeated invalid-token attempts from one IP", %{conn: conn} do
      conn = with_ip(conn)
      # ip_limit is 2 failures; the 3rd request should be rate-limited.
      for _ <- 1..2 do
        conn
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get(~p"/api/tasks/next")
      end

      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get(~p"/api/tasks/next")

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
    end

    test "a valid token still authenticates within the budget", %{conn: conn} do
      conn = with_ip(conn)
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {_token, plain}} = ApiTokens.create_api_token(user, board, %{name: "T"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain}")
        |> get(~p"/api/tasks/next")

      assert conn.status != 429
    end
  end
end
