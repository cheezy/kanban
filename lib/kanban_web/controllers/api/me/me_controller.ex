defmodule KanbanWeb.API.Me.MeController do
  @moduledoc """
  `GET /api/me` (W2747, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.3):
  what the mobile app needs at launch and after every sign-in.

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`.
  `app_unlocked` comes from `Kanban.Plans` and nothing the app sends. The
  response only ever gains fields (design §7.2): never remove or rename one a
  supported app version reads.
  """
  use KanbanWeb, :controller

  alias Kanban.Devices.AppPolicy
  alias Kanban.Plans
  alias Kanban.Workspaces

  def show(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns
    # One consistent pair, so a concurrent removal never shows the old
    # Organization beside the new, empty workspace list.
    {membership, workspaces} =
      Workspaces.list_workspaces_with_membership(scope.user, scope.organization_membership)

    render(conn, :show,
      user: scope.user,
      membership: membership,
      workspaces: workspaces,
      app_unlocked: Plans.membership_unlocked?(membership),
      min_versions: AppPolicy.min_versions(),
      limits: AppPolicy.phone_limits(),
      device: device
    )
  end
end
