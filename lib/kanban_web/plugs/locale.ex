defmodule KanbanWeb.Plugs.Locale do
  @moduledoc """
  A plug to set the locale from session or default to English.

  A supported `?locale=` query parameter is stored in the session first, so a
  link can open a page in a given language and keep it for the visit. The
  announcement email's links carry it, so they open in the email's language.
  An unsupported value is ignored.
  """
  import Plug.Conn

  @supported_locales Gettext.known_locales(KanbanWeb.Gettext)

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

  defp put_requested_locale(%{query_params: %{"locale" => locale}} = conn),
    do: set_locale(conn, locale)

  defp put_requested_locale(conn), do: conn
end
