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
      api_token: %{scale_ms: 60_000, ip_limit: 2},
      two_factor: %{scale_ms: 300_000, id_limit: 3},
      two_factor_challenge: %{scale_ms: 300_000, ip_limit: 2},
      two_factor_daily: %{scale_ms: 86_400_000, id_limit: 2}
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

  describe "two-factor sign-in challenge (controller)" do
    import Kanban.TwoFactorHelpers

    alias KanbanWeb.TwoFactorPending

    @throttled "Too many attempts. Please wait a few minutes and try again."

    # recycle/1 resets remote_ip between requests, so every request sets it.
    defp challenge(conn, ip, user) do
      %{conn | remote_ip: ip}
      |> post(~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })
      |> recycle()
      |> Map.put(:remote_ip, ip)
    end

    defp verify(conn, code) do
      post(conn, ~p"/users/two-factor", %{"two_factor" => %{"code" => code, "mode" => "totp"}})
    end

    defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}

    test "wrong codes from one IP across accounts trip the IP limit", %{conn: conn} do
      ip = random_ip()
      [user_a, user_b] = [user_fixture(), user_fixture()]
      %{secret: secret_a} = enroll(user_a)
      enroll(user_b)

      for user <- [user_a, user_b] do
        failed = conn |> challenge(ip, user) |> verify("000000")
        assert redirected_to(failed) == ~p"/users/two-factor"
      end

      conn = conn |> challenge(ip, user_a) |> verify(code(secret_a, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @throttled
      refute get_session(conn, :user_token)
      assert TwoFactorPending.get(conn) == {:error, :expired}
    end

    test "a user over the per-user limit is refused even with a correct code", %{conn: conn} do
      user = user_fixture()
      %{secret: secret} = enroll(user)

      for _ <- 1..3, do: Kanban.RateLimit.check(:two_factor, identity: "user:#{user.id}")

      conn = conn |> challenge(random_ip(), user) |> verify(code(secret, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @throttled
      refute get_session(conn, :user_token)
      assert TwoFactorPending.get(conn) == {:error, :expired}
    end

    test "wrong codes count towards the user's daily cap, from any IP", %{conn: conn} do
      # Room under the 5-minute per-user limit, so only the daily cap can refuse.
      limits = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(
        :kanban,
        Kanban.RateLimit,
        Keyword.put(limits, :two_factor, %{scale_ms: 300_000, id_limit: 10})
      )

      user = user_fixture()
      %{secret: secret} = enroll(user)

      for _ <- 1..2 do
        failed = conn |> challenge(random_ip(), user) |> verify("000000")
        assert redirected_to(failed) == ~p"/users/two-factor"
      end

      conn = conn |> challenge(random_ip(), user) |> verify(code(secret, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @throttled
      refute get_session(conn, :user_token)
    end

    test "attempts refused by the atomic per-user count get the throttle message", %{
      conn: conn
    } do
      user = user_fixture()
      enroll(user)
      marker = TwoFactorPending.new(user.id, false)

      # Enrolling spent one of the 3 per-user attempts and this spends one
      # more, so exactly one of the concurrent requests can win the last one.
      Kanban.RateLimit.check(:two_factor, identity: "user:#{user.id}")

      messages =
        1..12
        |> Task.async_stream(
          fn _ ->
            %{conn | remote_ip: random_ip()}
            |> init_test_session(two_factor_pending: marker)
            |> verify("000000")
            |> then(&Phoenix.Flash.get(&1.assigns.flash, :error))
          end,
          max_concurrency: 12
        )
        |> Enum.map(fn {:ok, message} -> message end)

      assert Enum.count(messages, &(&1 == "That code is not valid. Check it and try again.")) == 1
      assert Enum.count(messages, &(&1 == @throttled)) == 11
    end

    test "uses the same message as a throttled password login", %{conn: conn} do
      ip = random_ip()
      email = unique_user_email()

      for _ <- 1..3 do
        post(%{conn | remote_ip: ip}, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong password!"}
        })
      end

      conn =
        post(%{conn | remote_ip: ip}, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong password!"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @throttled
    end
  end
end
