defmodule Kanban.Accounts.AccountDeletionRateLimitTest do
  # async: false because the limiter is toggled on globally here; the broad
  # suite runs with it off.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Repo

  setup do
    previous = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      account_delete: %{scale_ms: 60_000, id_limit: 2}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, previous) end)
  end

  test "refuses after too many wrong passwords, before checking the password" do
    user = user_fixture()
    scope = Scope.for_user(user)

    assert {:error, :invalid_password} =
             Accounts.delete_own_account(scope, "wrong one", "delete my account")

    assert {:error, :invalid_password} =
             Accounts.delete_own_account(scope, "wrong two", "delete my account")

    assert {:error, :rate_limited} =
             Accounts.delete_own_account(scope, valid_user_password(), "delete my account")

    assert Repo.get(User, user.id)
  end

  test "wrong passwords sent at once cannot get past the limit" do
    user = user_fixture()
    scope = Scope.for_user(user)

    results =
      1..20
      |> Task.async_stream(
        fn n -> Accounts.delete_own_account(scope, "wrong #{n}", "delete my account") end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Only the attempts that got past the counter reached bcrypt.
    assert Enum.count(results, &(&1 == {:error, :invalid_password})) <= 2
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) >= 18
    assert Repo.get(User, user.id)
  end

  test "a correct password within the limit deletes the account" do
    user = user_fixture()
    scope = Scope.for_user(user)

    assert {:error, :invalid_password} =
             Accounts.delete_own_account(scope, "wrong one", "delete my account")

    assert {:ok, %{user: %User{}}} =
             Accounts.delete_own_account(scope, valid_user_password(), "delete my account")

    refute Repo.get(User, user.id)
  end

  test "a wrong confirmation phrase does not use up an attempt" do
    user = user_fixture()
    scope = Scope.for_user(user)

    for _ <- 1..5 do
      assert {:error, :invalid_confirmation} =
               Accounts.delete_own_account(scope, "wrong", "not the phrase")
    end

    assert {:ok, _deleted} =
             Accounts.delete_own_account(scope, valid_user_password(), "delete my account")
  end

  test "the settings page says to wait after too many wrong passwords", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings?section=danger_zone")
    lv |> element("#open-delete-account") |> render_click()

    for password <- ["wrong one", "wrong two", valid_user_password()] do
      lv
      |> form("#delete-account-form", %{
        "delete_account" => %{"password" => password, "confirmation" => "delete my account"}
      })
      |> render_submit()
    end

    assert render(lv) =~ "Too many wrong passwords. Try again in a few minutes."
    assert Repo.get(User, user.id)
  end

  test "the default limit for the surface is five wrong passwords in five minutes" do
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true)

    assert Kanban.RateLimit.__limits__(:account_delete) == %{scale_ms: 300_000, id_limit: 5}
  end
end
