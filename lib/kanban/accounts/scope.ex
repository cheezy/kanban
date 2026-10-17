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

  `organization_membership` is the user's `Kanban.Organizations.OrganizationMember`
  with its Organization preloaded (without the contact fields), or `nil` when the
  user belongs to no Organization. `KanbanWeb.UserAuth` loads it for every
  controller request and LiveView mount; scopes built elsewhere (API requests,
  background jobs) leave it `nil`.
  """

  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrganizationMember

  @type t :: %__MODULE__{}

  defstruct user: nil,
            unread_notifications: nil,
            two_factor_reminder: false,
            organization_membership: nil

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
end
