defmodule KanbanWeb.LocaleOnMount do
  @moduledoc """
  Ensures locale is set from session on LiveView mount.
  """
  import Phoenix.Component

  def on_mount(:set_locale, _params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(KanbanWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end
