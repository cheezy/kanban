defmodule KanbanWeb.UserAuth.OrganizationTwoFactorGate do
  @moduledoc """
  Enforces an Organization's two-factor requirement
  (`Kanban.Organizations.SecurityPolicies`) on authenticated browser requests.

  It is both a plug and an on_mount hook, and the router places it after
  `KanbanWeb.UserAuth` has built `current_scope`:

    * the plug runs in the authenticated controller scopes (through the
      router's `:enforce_organization_two_factor` pipeline), which also covers
      the first, disconnected render of every LiveView there;
    * `on_mount(:enforce, ...)` runs in the authenticated and admin
      `live_session`s, for the connected mount and live navigation;
    * `on_mount(:banner, ...)` runs in the settings `live_session` only. It
      shows the banner but never redirects, because the settings page is
      where the redirect leads.

  For a member whose Organization requires two-factor and who has not turned
  it on, the scope's `two_factor_deadline` is set during the grace period, so
  `KanbanWeb.Layouts.app/1` shows the banner. Once the deadline has passed,
  every request is redirected to the two-factor section of the settings page
  until they enroll. Enrolling, the policy being turned off, or leaving the
  Organization ends it on the next request, because nothing is cached between
  requests. While a LiveView stays open across the deadline, its
  `handle_params` hook re-checks the policy on the next navigation.

  Exempt by where the router places it: the settings page and password update
  (where the member enrolls), log-in, the two-factor sign-in step and log-out,
  public pages, and every `/api` route, which never builds a browser session.

  ## Single sign-on

  A session whose identity provider owns MFA satisfies the policy. The OIDC
  and SAML sign-in flows mark such a session by putting `sso_session_key/0`
  with the value `true` into the session, after
  `KanbanWeb.UserAuth.log_in_user/3` has renewed it. Only that server-written
  session value counts; request params are never read.
  """
  @behaviour Plug

  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Organizations.SecurityPolicies

  @sso_session_key "sso_authenticated"

  @doc """
  The session key a single sign-on login sets to `true`.
  """
  @spec sso_session_key() :: String.t()
  def sso_session_key, do: @sso_session_key

  @doc "Where an overdue member is sent: the two-factor section of the settings page."
  @spec redirect_path() :: String.t()
  def redirect_path, do: ~p"/users/settings?section=two_factor"

  @doc """
  What the policy means for this scope and session: `:ok` (no requirement,
  enrolled, signed in through SSO, or no signed-in member), `{:grace,
  deadline}` or `{:overdue, deadline}`.
  """
  @spec evaluate(Scope.t() | nil, boolean()) ::
          :ok | {:grace, DateTime.t()} | {:overdue, DateTime.t()}
  def evaluate(scope, sso?)

  def evaluate(_scope, true), do: :ok

  def evaluate(%Scope{user: %User{} = user, organization_membership: membership}, _sso?)
      when not is_nil(membership) do
    case SecurityPolicies.two_factor_status(user, membership) do
      {:grace, _deadline} = grace -> grace
      {:overdue, _deadline} = overdue -> overdue
      _not_required_or_enrolled -> :ok
    end
  end

  def evaluate(_scope, _sso?), do: :ok

  # --- plug ------------------------------------------------------------------

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    scope = conn.assigns[:current_scope]

    case evaluate(scope, get_session(conn, @sso_session_key) == true) do
      {:grace, deadline} ->
        assign(conn, :current_scope, %{scope | two_factor_deadline: deadline})

      {:overdue, _deadline} ->
        conn
        |> put_flash(:error, overdue_message())
        |> redirect(to: redirect_path())
        |> halt()

      :ok ->
        conn
    end
  end

  # --- on_mount ----------------------------------------------------------------

  @doc """
  `:enforce` redirects an overdue member to the settings page and marks a
  member in their grace period; `:banner` only marks, for grace and overdue
  alike, and never redirects.
  """
  def on_mount(:enforce, _params, session, socket) do
    case evaluate(socket.assigns[:current_scope], sso_session?(session)) do
      {:grace, deadline} ->
        socket =
          socket
          |> put_deadline(deadline)
          |> Phoenix.LiveView.attach_hook(
            :organization_two_factor,
            :handle_params,
            &__MODULE__.recheck_params/3
          )

        {:cont, socket}

      {:overdue, _deadline} ->
        {:halt, redirect_socket(socket)}

      :ok ->
        {:cont, socket}
    end
  end

  def on_mount(:banner, _params, session, socket) do
    case evaluate(socket.assigns[:current_scope], sso_session?(session)) do
      {_grace_or_overdue, deadline} -> {:cont, put_deadline(socket, deadline)}
      :ok -> {:cont, socket}
    end
  end

  @doc """
  The `handle_params` hook `on_mount(:enforce, ...)` attaches: once the
  deadline shown on mount has passed, re-reads the membership and policy and
  redirects if the member is now overdue; otherwise clears or keeps the banner.
  """
  @spec recheck_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def recheck_params(_params, _uri, socket) do
    %Scope{user: user, two_factor_deadline: deadline} = socket.assigns.current_scope

    if deadline && DateTime.compare(DateTime.utc_now(), deadline) != :lt do
      recheck_overdue(user, socket)
    else
      {:cont, socket}
    end
  end

  defp recheck_overdue(user, socket) do
    case SecurityPolicies.two_factor_status_for_user(user) do
      {:overdue, _deadline} -> {:halt, redirect_socket(socket)}
      {:grace, deadline} -> {:cont, put_deadline(socket, deadline)}
      _not_required_or_enrolled -> {:cont, put_deadline(socket, nil)}
    end
  end

  defp sso_session?(session), do: Map.get(session, @sso_session_key) == true

  defp put_deadline(socket, deadline) do
    scope = %{socket.assigns.current_scope | two_factor_deadline: deadline}
    Phoenix.Component.assign(socket, :current_scope, scope)
  end

  defp redirect_socket(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, overdue_message())
    |> Phoenix.LiveView.redirect(to: redirect_path())
  end

  defp overdue_message do
    gettext(
      "Your Organization requires two-factor authentication. Turn it on to keep using Stride."
    )
  end
end
