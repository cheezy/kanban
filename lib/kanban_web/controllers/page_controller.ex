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

    render(conn, :home, [has_boards: has_boards] ++ seo(:home))
  end

  def about(conn, _params) do
    render(conn, :about, seo(:about))
  end

  def hit_me(conn, _params) do
    render(conn, :hit_me, seo(:hit_me))
  end

  def pricing(conn, _params) do
    render(conn, :pricing, seo(:pricing))
  end

  def acceptable_use(conn, _params) do
    render(conn, :acceptable_use, seo(:acceptable_use))
  end

  def privacy(conn, _params) do
    render(conn, :privacy, seo(:privacy))
  end

  def product(conn, _params) do
    render(conn, :product, seo(:product))
  end

  def security(conn, _params) do
    render(conn, :security, seo(:security))
  end

  def terms(conn, _params) do
    render(conn, :terms, seo(:terms))
  end

  def workflows(conn, _params) do
    render(conn, :workflows, seo(:workflows))
  end

  def tango(conn, _params) do
    render(conn, :tango, seo(:tango))
  end

  def changelog(conn, _params) do
    render(conn, :changelog, seo(:changelog))
  end

  # The page_title and meta_description every public page passes to seo_head
  # (KanbanWeb.SeoComponents, rendered by the root layouts). A function, not a
  # module attribute, so gettext runs per request in the visitor's locale.
  # test/kanban_web/controllers/page_controller_seo_test.exs walks every GET
  # route on this controller and fails when one lacks a clause here, or when
  # two pages share a title or a description.
  @doc """
  The `page_title` and `meta_description` of a public page, in the current
  locale. `KanbanWeb.LlmsTxt` reuses the descriptions, so `/llms.txt` says
  what each page says about itself.
  """
  @spec seo(atom()) :: [page_title: String.t(), meta_description: String.t()]
  def seo(:home),
    do: [
      page_title: gettext("Stride: kanban for people and AI agents"),
      meta_description:
        gettext(
          "Plan, claim and ship work on one kanban board shared by your team and its AI agents, with workflow hooks, review gates and a full REST API."
        )
    ]

  def seo(:about),
    do: [
      page_title: gettext("About Stride"),
      meta_description:
        gettext(
          "How Stride was built, who it is for, how people and AI agents work together on one board, and how you can get involved in the project."
        )
    ]

  def seo(:acceptable_use),
    do: [
      page_title: gettext("Acceptable Use Policy"),
      meta_description:
        gettext(
          "What you may and may not do with Stride and the AI agents you connect to it, and what happens when an account breaks these rules."
        )
    ]

  def seo(:hit_me),
    do: [
      page_title: gettext("Half-day AI proof-of-concept sessions"),
      meta_description:
        gettext(
          "Book a half-day session in which your team and AI agents set up a Stride board and deliver the first part of your proof of concept."
        )
    ]

  def seo(:pricing),
    do: [
      page_title: gettext("Pricing"),
      meta_description:
        gettext(
          "Compare the Stride plans for individuals, small teams and larger organizations, and see what each plan includes for people, boards and support."
        )
    ]

  def seo(:privacy),
    do: [
      page_title: gettext("Privacy Policy"),
      meta_description:
        gettext(
          "What personal information Stride collects, how it is used and shared, how long it is kept, and the rights you have over your data."
        )
    ]

  def seo(:product),
    do: [
      page_title: gettext("Product"),
      meta_description:
        gettext(
          "A tour of Stride: the board your people and agents share, goals that track their own progress, built-in review, and metrics on how work flows."
        )
    ]

  def seo(:security),
    do: [
      page_title: gettext("Security"),
      meta_description:
        gettext(
          "How Stride protects your account and data: authentication and access control, encryption in transit and at rest, and application-level safeguards."
        )
    ]

  def seo(:terms),
    do: [
      page_title: gettext("Terms of Service"),
      meta_description:
        gettext(
          "The terms that govern your Stride account, the content you add, the AI agents you connect, and how either side can end the agreement."
        )
    ]

  def seo(:workflows),
    do: [
      page_title: gettext("Workflows"),
      meta_description:
        gettext(
          "How work moves through a Stride board from Backlog to Done: getting ready, claiming tasks, running hooks and deciding what needs review."
        )
    ]

  def seo(:tango),
    do: [
      page_title: gettext("The People Behind This App"),
      meta_description:
        gettext(
          "Meet the people and the AI collaborator behind Stride, why they built it, and how they can help your team build what comes next."
        )
    ]

  def seo(:changelog),
    do: [
      page_title: gettext("Changelog"),
      meta_description:
        gettext(
          "Release notes for Stride: the new features, improvements and fixes in each release, with the newest release listed first."
        ),
      feed_path: ~p"/changelog/feed.xml",
      feed_title: gettext("Stride releases")
    ]

  def set_locale(conn, %{"locale" => locale}) do
    conn
    |> remember_locale(conn.assigns[:current_scope], locale)
    |> redirect(to: get_redirect_path(conn))
  end

  # A signed-in user's choice is also stored on the account, so the service
  # announcement, audit-stream, notification and weekly digest emails can use
  # it; the account emails (Kanban.Accounts.UserNotifier) still render in the
  # default locale. An unsupported locale is
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
