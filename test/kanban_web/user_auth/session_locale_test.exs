defmodule KanbanWeb.UserAuth.SessionLocaleTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Repo
  alias KanbanWeb.UserAuth.SessionLocale

  setup %{conn: conn} do
    %{conn: init_test_session(conn, %{}), user: user_fixture()}
  end

  describe "sync/3" do
    test "saves a choice to the account", %{conn: conn, user: user} do
      conn = SessionLocale.sync(conn, user, "de")

      assert Repo.reload!(user).locale == "de"
      refute get_session(conn, :locale)
    end

    test "leaves the account and session alone when the choice is already saved",
         %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "fr")
      conn = put_session(conn, :locale, "es")

      assert SessionLocale.sync(conn, user, "fr") == conn
      assert Repo.reload!(user).locale == "fr"
    end

    test "refuses an unsupported choice", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "fr")

      SessionLocale.sync(conn, user, "xx")

      assert Repo.reload!(user).locale == "fr"
    end

    test "without a choice keeps a link's language and saves nothing", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "pt")

      conn = conn |> put_session(:locale, "es") |> SessionLocale.sync(user, nil)

      assert get_session(conn, :locale) == "es"
      assert Repo.reload!(user).locale == "pt"
    end

    test "without a choice or a session language loads the saved one", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "zh")

      assert conn |> SessionLocale.sync(user, nil) |> get_session(:locale) == "zh"
    end
  end

  describe "load_saved/2" do
    test "loads the account's language into a session with none", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "ja")

      assert conn |> SessionLocale.load_saved(user) |> get_session(:locale) == "ja"
    end

    test "keeps a language the session already has", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user_locale(user, "ja")

      conn = conn |> put_session(:locale, "de") |> SessionLocale.load_saved(user)

      assert get_session(conn, :locale) == "de"
    end

    test "leaves the session unset when the account has no language", %{conn: conn, user: user} do
      refute conn |> SessionLocale.load_saved(user) |> get_session(:locale)
    end
  end
end
