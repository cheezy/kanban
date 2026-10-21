defmodule Kanban.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Kanban.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.

  `unread_notifications` is the user's unread notification count. It is
  `nil` until `KanbanWeb.NotificationsOnMount` loads it, so controller-rendered
  pages (which never run that hook) show the bell without a badge.

  `two_factor_reminder` is true only on the page a user without two-factor
  lands on right after a password sign-in. `KanbanWeb.TwoFactorReminderOnMount`
  sets it from the `:two_factor_reminder` flash; controller pages and later
  navigations leave it false, so `KanbanWeb.Layouts.app/1` shows no card there.

  `two_factor_deadline` is the `DateTime` by which the user must turn on
  two-factor because their Organization requires it, or `nil`.
  `KanbanWeb.UserAuth.OrganizationTwoFactorGate` sets it while the user is in
  their grace period (and, on the settings page only, after it has passed), and
  `KanbanWeb.Layouts.app/1` reads it to render the grace banner.

  `organization_membership` is the user's `Kanban.Organizations.OrganizationMember`
  with its Organization preloaded (without the contact fields), or `nil` when the
  user belongs to no Organization. `KanbanWeb.UserAuth` loads it for every
  controller request and LiveView mount; scopes built elsewhere (API requests,
  background jobs) leave it `nil`.

  `notifications_locked` is true while paid plans are enforced and the user
  belongs to no Organization (`Kanban.Plans.membership_unlocked?/1`).
  `KanbanWeb.UserAuth` sets it once per controller request and LiveView mount,
  from the membership it has just loaded, so the bell and the notification
  pages read it without a query. Scopes built elsewhere leave it `false`.

  `workspace` is the `Kanban.Workspaces.Workspace` the caller is acting in, or
  `nil`, and `workspaces` the org workspaces their switcher lists (`[]` without
  an Organization). `KanbanWeb.UserAuth` sets both for every controller request
  and LiveView mount through `Kanban.Workspaces.Current.put_current/2`, which
  verifies the session's `current_workspace_id` against that list; scopes built
  elsewhere leave `nil` and `[]`. `put_workspace/2` records a resolved
  workspace.
  """

  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Workspaces.Workspace

  @type t :: %__MODULE__{}

  defstruct user: nil,
            unread_notifications: nil,
            two_factor_reminder: false,
            two_factor_deadline: nil,
            organization_membership: nil,
            notifications_locked: false,
            workspace: nil,
            workspaces: []

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Sets the scope's Organization membership, or clears it with `nil`.

  ## Examples

      iex> put_organization_membership(scope, membership)
      %Scope{organization_membership: %OrganizationMember{}}

  """
  def put_organization_membership(%__MODULE__{} = scope, %OrganizationMember{} = membership) do
    %{scope | organization_membership: membership}
  end

  def put_organization_membership(%__MODULE__{} = scope, nil) do
    %{scope | organization_membership: nil}
  end

  @doc """
  Sets the workspace the scope acts in, or clears it with `nil`.

  ## Examples

      iex> put_workspace(scope, workspace)
      %Scope{workspace: %Workspace{}}

  """
  def put_workspace(%__MODULE__{} = scope, %Workspace{} = workspace) do
    %{scope | workspace: workspace}
  end

  def put_workspace(%__MODULE__{} = scope, nil) do
    %{scope | workspace: nil}
  end
end
