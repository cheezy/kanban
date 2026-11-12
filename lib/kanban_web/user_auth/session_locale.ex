defmodule KanbanWeb.UserAuth.SessionLocale do
  @moduledoc """
  How `KanbanWeb.UserAuth` reconciles the session's language with the one
  saved to the account.

  The session's language has two writers, and only one of them is a choice:

    * `KanbanWeb.Plugs.Locale.choose_locale/2`, called by the CSRF-protected
      `POST /locale/:locale` (`PageController.set_locale/2`) for a signed-out
      visitor, is a language chosen from a language menu. It also leaves a
      choice mark. Signed in, that POST saves to the account straight away and
      leaves no mark.
    * A `?locale=` query parameter (`KanbanWeb.Plugs.Locale`) shows a page in
      that language for the visit, as the announcement email's links do. It
      leaves no mark, so a link never changes the account.

  At sign-in (`sync/3`) a marked choice is saved to the account, which the
  service announcement email renders in; `Kanban.Accounts.update_user_locale/2`
  refuses an unsupported value. Without a choice, a link's language stays for
  the visit and the account is left alone, and with no session language at
  all the account's saved language is loaded.

  A session restored from the remember-me cookie never passes through sign-in,
  so `load_saved/2` loads the account's saved language into a session that has
  none. A `?locale=` on that same request still wins, because the locale plug
  runs after the scope is fetched.
  """
  import Plug.Conn

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias KanbanWeb.Plugs.Locale

  @doc """
  Saves `choice`, the locale taken from the session before it was renewed with
  `KanbanWeb.Plugs.Locale.take_choice/1`, to the account at sign-in. Without
  one, it loads the account's saved language into a session with no language.
  """
  def sync(conn, %User{locale: stored} = user, choice) do
    case choice do
      nil -> load_saved(conn, user)
      ^stored -> conn
      chosen -> tap(conn, fn _ -> Accounts.update_user_locale(user, chosen) end)
    end
  end

  @doc """
  Loads the account's saved language into a session that has no language. A
  session that already has one, and an account with none, are left alone.
  """
  def load_saved(conn, %User{locale: stored}) do
    case get_session(conn, :locale) do
      nil -> Locale.set_locale(conn, stored)
      _visit_language -> conn
    end
  end
end
