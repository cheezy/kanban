defmodule KanbanWeb.PageController do
  use KanbanWeb, :controller

  alias Kanban.Accounts
  alias Kanban.Accounts.User

  # Public marketing surfaces — render under the marketing layout (which
  # provides the marketing nav + footer chrome) instead of the default
  # app layout (which provides the in-app nav).
  plug :put_root_layout,
       [html: {KanbanWeb.Layouts, :marketing}]
       when action in [
              :acceptable_use,
              :hit_me,
              :home,
              :pricing,
              :privacy,
              :product,
              :security,
              :terms,
              :workflows
            ]

  # Pages reachable from the in-app sidebar (About) or from About itself
  # (Tango, Changelog) render under the app shell so the sidebar stays
  # visible for authenticated users.
  plug :put_root_layout,
       [html: {KanbanWeb.Layouts, :app_chrome}]
       when action in [:about, :tango, :changelog]

  def home(conn, _params) do
    has_boards =
      case conn.assigns[:current_scope] do
        %{user: user} when not is_nil(user) -> Kanban.Boards.user_has_boards?(user)
        _ -> false
      end

    render(conn, :home, has_boards: has_boards)
  end

  def about(conn, _params) do
    render(conn, :about)
  end

  def hit_me(conn, _params) do
    render(conn, :hit_me, page_title: gettext("Half-day AI proof-of-concept sessions"))
  end

  def pricing(conn, _params) do
    render(conn, :pricing)
  end

  def acceptable_use(conn, _params) do
    render(conn, :acceptable_use)
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def product(conn, _params) do
    render(conn, :product)
  end

  def security(conn, _params) do
    render(conn, :security)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end

  def workflows(conn, _params) do
    render(conn, :workflows)
  end

  def tango(conn, _params) do
    render(conn, :tango)
  end

  def changelog(conn, _params) do
    render(conn, :changelog)
  end

  def set_locale(conn, %{"locale" => locale}) do
    conn
    |> remember_locale(conn.assigns[:current_scope], locale)
    |> redirect(to: get_redirect_path(conn))
  end

  # A signed-in user's choice is also stored on the account, so the service
  # announcement email (Kanban.Notifications.AnnouncementWorker) can use it;
  # other emails still render in the default locale. An unsupported locale is
  # refused there and changes nothing, exactly as the session plug ignores it.
  # Signed out, the choice is marked in the session instead, and sign-in saves
  # it (KanbanWeb.UserAuth.SessionLocale). A signed-in choice leaves no mark, so
  # a later re-authentication cannot overwrite a language changed elsewhere.
  defp remember_locale(conn, %{user: %User{} = user}, locale) do
    Accounts.update_user_locale(user, locale)
    KanbanWeb.Plugs.Locale.set_locale(conn, locale)
  end

  defp remember_locale(conn, _scope, locale),
    do: KanbanWeb.Plugs.Locale.choose_locale(conn, locale)

  # Back to the page the language was chosen on, query string included, so a
  # Settings ?section= link keeps its section. Only a path Phoenix accepts as
  # local is used: one starting with "//" (protocol-relative) or carrying unsafe
  # characters would make redirect/2 raise, so it falls back to the home page.
  defp get_redirect_path(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{path: path, query: query} when is_binary(path) <- URI.parse(referer),
         target = with_query(path, query),
         :ok <- Phoenix.URL.classify_local_path(target) do
      target
    else
      _ -> "/"
    end
  end

  # A ?locale= on the page the choice was made on is dropped: kept, the
  # redirected request would put the link's language back over the choice.
  defp with_query(path, query) when query in [nil, ""], do: path

  defp with_query(path, query) do
    query
    |> URI.query_decoder()
    |> Enum.reject(fn {key, _value} -> key == "locale" end)
    |> URI.encode_query()
    |> then(&with_query_string(path, &1))
  end

  defp with_query_string(path, ""), do: path
  defp with_query_string(path, query), do: path <> "?" <> query
end
