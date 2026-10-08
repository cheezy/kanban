defmodule Kanban.Accounts.TwoFactorRateLimitTest do
  # async: false — turns Kanban.RateLimit on globally (the suite runs with it
  # off). Each test uses a fresh user, so the shared bucket store cannot bleed
  # state between tests.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts

  @limit 3

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      two_factor: %{scale_ms: 60_000, id_limit: @limit}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    user = user_fixture()
    {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)

    %{user: user, secret: secret}
  end

  defp code(secret, offset_steps \\ 0) do
    NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset_steps * 30)
  end

  defp wrong(secret, offset_steps \\ 0) do
    if code(secret, offset_steps) == "000000", do: "111111", else: "000000"
  end

  defp enable(%{user: user, secret: secret}) do
    {:ok, codes} = Accounts.confirm_two_factor_enrollment(user, code(secret))
    codes
  end

  test "after the limit of attempts, even a correct code is refused", %{
    user: user,
    secret: secret
  } do
    for _ <- 1..@limit do
      assert Accounts.confirm_two_factor_enrollment(user, wrong(secret)) ==
               {:error, :invalid_code}
    end

    assert Accounts.confirm_two_factor_enrollment(user, code(secret)) == {:error, :rate_limited}
    refute Accounts.two_factor_enabled?(user)
  end

  test "every attempt counts, correct ones too", ctx do
    # enabling is the first attempt
    [recovery | _] = enable(ctx)

    assert Accounts.consume_recovery_code(ctx.user, recovery) == :ok
    assert Accounts.valid_two_factor_code?(ctx.user, code(ctx.secret, 1))

    refute Accounts.valid_two_factor_code?(ctx.user, code(ctx.secret, 1))
    assert Accounts.consume_recovery_code(ctx.user, "aaaaa-aaaaa") == {:error, :rate_limited}
  end

  test "attempts on any check share one per-user budget", ctx do
    # enabling is the first attempt
    enable(ctx)

    refute Accounts.valid_two_factor_code?(ctx.user, wrong(ctx.secret, 1))
    assert Accounts.consume_recovery_code(ctx.user, "aaaaa-aaaaa") == {:error, :invalid_code}

    assert Accounts.regenerate_recovery_codes(ctx.user, code(ctx.secret, 1)) ==
             {:error, :rate_limited}

    assert Accounts.disable_two_factor(ctx.user, code(ctx.secret, 1)) == {:error, :rate_limited}
    refute Accounts.valid_two_factor_code?(ctx.user, code(ctx.secret, 1))
    assert Accounts.two_factor_enabled?(ctx.user)
  end

  test "attempts sent at once cannot get past the limit", ctx do
    enable(ctx)

    results =
      1..20
      |> Task.async_stream(fn _ -> Accounts.consume_recovery_code(ctx.user, "aaaaa-aaaaa") end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # one attempt went on enabling, so at most @limit - 1 reach the code check
    assert Enum.count(results, &(&1 == {:error, :invalid_code})) <= @limit - 1
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) >= 20 - (@limit - 1)
  end

  test "one user's attempts do not throttle another user", ctx do
    for _ <- 1..@limit, do: Accounts.confirm_two_factor_enrollment(ctx.user, wrong(ctx.secret))

    other = user_fixture()
    {:ok, %{secret: other_secret}} = Accounts.begin_two_factor_enrollment(other)

    assert {:ok, _codes} = Accounts.confirm_two_factor_enrollment(other, code(other_secret))
  end

  test "the settings page tells a throttled user to wait", %{conn: conn} = ctx do
    enable(ctx)

    {:ok, lv, _html} =
      conn |> log_in_user(ctx.user) |> live(~p"/users/settings?section=two_factor")

    for _ <- 1..@limit do
      lv |> form("#two-factor-disable-form", %{"code" => wrong(ctx.secret, 1)}) |> render_submit()
    end

    html =
      lv |> form("#two-factor-disable-form", %{"code" => code(ctx.secret, 1)}) |> render_submit()

    assert html =~ "Too many attempts. Please wait a few minutes and try again."
    assert Accounts.two_factor_enabled?(ctx.user)
  end
end
