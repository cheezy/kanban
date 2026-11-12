defmodule KanbanWeb.Plugs.Locale do
  @moduledoc """
  A plug to set the locale from session or default to English.

  A supported `?locale=` query parameter is stored in the session first, so a
  link can open a page in a given language and keep it for the visit. The
  announcement email's links carry it, so they open in the email's language.
  An unsupported value is ignored.

  A link's language is only shown, never chosen: `choose_locale/2`, which the
  CSRF-protected `POST /locale/:locale` calls, is the one writer of the choice
  mark that sign-in saves to the account (`KanbanWeb.UserAuth.SessionLocale`).
  """
  import Plug.Conn

  @supported_locales Gettext.known_locales(KanbanWeb.Gettext)
  @choice_key :locale_choice

  def init(default), do: default

  def call(conn, _default) do
    conn = conn |> fetch_query_params() |> put_requested_locale()

    # Check both string and atom keys for backwards compatibility
    locale = get_session(conn, :locale) || get_session(conn, "locale") || "en"

    if locale in @supported_locales do
      Gettext.put_locale(KanbanWeb.Gettext, locale)
    end

    conn
  end

  @doc """
  Sets the locale in the session and updates Gettext.
  """
  def set_locale(conn, locale) when locale in @supported_locales do
    Gettext.put_locale(KanbanWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> put_session("locale", locale)
  end

  def set_locale(conn, _locale), do: conn

  @doc """
  Sets the locale as `set_locale/2` does and marks it as the visitor's own
  choice, so signing in saves it to the account. An unsupported locale changes
  nothing.
  """
  def choose_locale(conn, locale) when locale in @supported_locales do
    conn
    |> set_locale(locale)
    |> put_session(@choice_key, locale)
  end

  def choose_locale(conn, _locale), do: conn

  @doc """
  Returns the locale chosen with `choose_locale/2`, or `nil` when none was,
  together with the conn with the mark removed.
  """
  def take_choice(conn) do
    {get_session(conn, @choice_key), delete_session(conn, @choice_key)}
  end

  defp put_requested_locale(%{query_params: %{"locale" => locale}} = conn),
    do: set_locale(conn, locale)

  defp put_requested_locale(conn), do: conn
end
