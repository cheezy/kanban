defmodule KanbanWeb.Admin.OrganizationLive.Index do
  @moduledoc """
  Site-admin list of every Organization, with its location, contact and
  org-admin and member counts.

  There is no delete action: an Organization is never deleted or downgraded.
  """
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares this
  # hook, but re-declaring it here keeps the LiveView admin-only even if the
  # route is ever moved out of that live_session.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.Organizations
  alias KanbanWeb.Admin.OrganizationLive.Form

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Organizations"))
     |> assign_organizations()}
  end

  # list_organizations/1 re-reads the actor's row, so an admin disabled or
  # demoted after the session loaded them gets an empty list and a flash.
  defp assign_organizations(socket) do
    case Organizations.list_organizations(socket.assigns.current_scope.user) do
      {:ok, organizations} ->
        assign(socket, :organizations, organizations)

      {:error, reason} ->
        socket
        |> assign(:organizations, [])
        |> put_flash(:error, Form.error_message(reason))
    end
  end

  defp location(organization) do
    [organization.city, organization.country]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> placeholder()
  end

  defp placeholder(""), do: "—"
  defp placeholder(nil), do: "—"
  defp placeholder(value), do: value
end
