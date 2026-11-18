defmodule KanbanWeb.API.Me.MeJSON do
  @moduledoc """
  JSON rendering for `GET /api/me` (W2747).

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.2).
  `priv/openapi/stride-api.json` documents the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. The device's push token, its approval key and its token hashes are
  never rendered, nor an Organization's contact fields.
  """

  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Workspaces.Workspace
  alias KanbanWeb.Avatar

  @doc """
  The person, their Organization and its workspaces, the plan status, the
  minimum app versions, the phone guard limits and the device.
  """
  def show(assigns) do
    %{
      data: %{
        user: user(assigns.user),
        organization: organization(assigns.membership),
        workspaces: Enum.map(assigns.workspaces, &workspace/1),
        app_unlocked: assigns.app_unlocked,
        min_app_versions: assigns.min_versions,
        limits: assigns.limits,
        device: device(assigns.device)
      }
    }
  end

  @doc """
  The person: their id, display name and avatar initials. The display name is
  their name, or their email when they have set none.
  """
  def user(%User{} = user) do
    display_name = display_name(user)

    %{
      id: user.id,
      display_name: display_name,
      initials: Avatar.initials(display_name, ~r/[\s@.]/)
    }
  end

  @doc """
  The person's Organization and their role in it, or `nil` without one.
  """
  def organization(%OrganizationMember{organization: organization, role: role}) do
    %{id: organization.id, name: organization.name, role: role}
  end

  def organization(nil), do: nil

  @doc """
  One workspace the person can see, for the board picker's grouping.
  """
  def workspace(%Workspace{} = workspace) do
    %{id: workspace.id, name: workspace.name, slug: workspace.slug}
  end

  @doc """
  The device the request's token belongs to.
  """
  def device(%Device{} = device) do
    %{
      id: device.id,
      name: device.name,
      platform: device.platform,
      device_class: device.device_class,
      model: device.model,
      os_version: device.os_version,
      app_version: device.app_version,
      last_seen_at: device.last_seen_at,
      signed_in_at: device.inserted_at
    }
  end

  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%User{email: email}) when is_binary(email), do: email
  defp display_name(_user), do: "?"
end
