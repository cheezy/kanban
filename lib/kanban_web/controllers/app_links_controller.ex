defmodule KanbanWeb.AppLinksController do
  @moduledoc """
  Serves the two association files that let a Stride link open the native
  app instead of the browser (W2764, docs/universal-links.md,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.20):

    * `/.well-known/apple-app-site-association` for iOS universal links, and
    * `/.well-known/assetlinks.json` for Android App Links.

  Both are public JSON, fetched by Apple's and Google's servers and by the
  phone itself without signing in. They go through the router's
  `:well_known` pipeline, which fetches no session, checks no CSRF token and
  never redirects, because a redirect or a cookie makes both verifiers refuse
  the file.

  The ids come from the `:app_links` application config, which
  `config/runtime.exs` builds from `STRIDE_IOS_TEAM_ID`,
  `STRIDE_IOS_BUNDLE_ID`, `STRIDE_ANDROID_PACKAGE` and
  `STRIDE_ANDROID_CERT_FINGERPRINTS`. An app is listed only when all of its
  ids are present, so with nothing configured both files list no apps. Every
  value here is public: a team id, a bundle id, a package name and the
  SHA-256 fingerprints of signing certificates, never a key or a secret.

  ## Which paths open the app

  Apple matches a link's path against `components/0` in order and the first
  match decides, where `*` matches any run of characters (including `/`) and
  `?` exactly one. Only six pages open the app:

      /review
      /agents
      /boards/:id
      /boards/:id/goals/:goal_id
      /boards/:id/tasks/:task_id/edit
      /targets/:id

  Because a wildcard also matches deeper paths and literal segments such as
  `new`, each wildcard is preceded by `exclude` entries for the routes it
  would otherwise catch, and none is a bare `*`. The controller test checks
  the list against every GET route in the router, so a new route that one of
  these patterns would catch fails it.

  Android takes no paths in this file: an App Links app declares the paths it
  handles in its own manifest, and this file only says which signed app may
  handle links for this host.
  """
  use KanbanWeb, :controller

  # An hour: the verifiers fetch rarely, and a changed id is seen the same day.
  @cache_control "public, max-age=3600"

  @handle_all_urls "delegate_permission/common.handle_all_urls"

  @spec apple(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def apple(conn, _params) do
    details =
      case apple_app_id(config()) do
        nil -> []
        app_id -> [%{appIDs: [app_id], components: components()}]
      end

    send_json(conn, %{applinks: %{details: details}})
  end

  @spec assetlinks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assetlinks(conn, _params) do
    statements =
      case android_target(config()) do
        nil -> []
        target -> [%{relation: [@handle_all_urls], target: target}]
      end

    send_json(conn, statements)
  end

  @doc """
  The ordered `components` of the Apple file: each entry is a path pattern,
  and an entry with `exclude: true` keeps the links it matches in the browser.
  """
  @spec components() :: [map()]
  def components do
    [
      %{"/" => "/review"},
      %{"/" => "/agents"},
      %{"/" => "/boards/?*/tasks/?*/edit"},
      %{"/" => "/boards/?*/goals/new", "exclude" => true},
      %{"/" => "/boards/?*/goals/?*/*", "exclude" => true},
      %{"/" => "/boards/?*/goals/?*"},
      %{"/" => "/boards/new", "exclude" => true},
      %{"/" => "/boards/?*/*", "exclude" => true},
      %{"/" => "/boards/?*"},
      %{"/" => "/targets/new", "exclude" => true},
      %{"/" => "/targets/archived", "exclude" => true},
      %{"/" => "/targets/?*/*", "exclude" => true},
      %{"/" => "/targets/?*"}
    ]
  end

  defp config, do: Application.get_env(:kanban, :app_links, [])

  # Apple's app id is the team id and the bundle id joined by a dot.
  defp apple_app_id(config) do
    team_id = config[:ios_team_id]
    bundle_id = config[:ios_bundle_id]

    if present?(team_id) and present?(bundle_id), do: team_id <> "." <> bundle_id
  end

  # A blank fingerprint is dropped, and with no fingerprint left the app is
  # not listed: a target with an empty list could never be verified.
  defp android_target(config) do
    package = config[:android_package]
    fingerprints = Enum.filter(config[:android_cert_fingerprints] || [], &present?/1)

    if present?(package) and fingerprints != [] do
      %{namespace: "android_app", package_name: package, sha256_cert_fingerprints: fingerprints}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp send_json(conn, body) do
    conn
    |> put_resp_header("cache-control", @cache_control)
    |> json(body)
  end
end
