defmodule KanbanWeb.OrgLive.Console do
  @moduledoc """
  The org console at `/org`, reachable only by an org-admin.

  It always shows the signed-in org-admin's own Organization: the id comes from
  the membership `KanbanWeb.UserAuth` loaded into `current_scope`, never from
  params. Sections follow the `KanbanWeb.UserLive.Settings` pattern, with an
  allow-listed `select_section` event. Choosing a section patches the URL to
  `/org?section=<name>`, so a section can be linked to and survives a reload:

    * Details - the Organization's name, address and contact, read-only. Only a
      site admin edits them.
    * Members - every member with name, email and role, read-only.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents, only: [section_tab: 1, settings_card: 1]

  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization

  # The router's live_session :require_authenticated_user lets in every
  # signed-in user. Re-declaring the org-admin gate here keeps the console
  # closed to members, free users and site admins even if the route is moved.
  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  @sections ["details", "members"]

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: %{user: user}, current_organization: %Organization{id: id}} =
      socket.assigns

    case Organizations.get_organization(id, user) do
      %Organization{} = organization ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Organization"))
         |> assign(:organization, organization)
         |> assign(:members, Organizations.list_members(organization))
         |> assign(:section, :details)}

      # The org-admin role was removed between the gate and this lookup.
      nil ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("You must be an org-admin of an Organization to access this page.")
         )
         |> redirect(to: ~p"/boards")}
    end
  end

  # ?section= opens that section; anything else, including an unknown name or
  # no parameter, shows Details.
  @impl true
  def handle_params(%{"section" => section}, _uri, socket) when section in @sections do
    {:noreply, assign(socket, :section, String.to_existing_atom(section))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :section, :details)}

  @impl true
  def handle_event("select_section", %{"section" => section}, socket)
      when section in @sections do
    {:noreply, push_patch(socket, to: ~p"/org?#{[section: section]}")}
  end

  # A crafted payload naming any other section leaves the console as it is.
  def handle_event("select_section", _params, socket), do: {:noreply, socket}

  defp sections do
    [
      {:details, gettext("Details"), gettext("name · address · contact")},
      {:members, gettext("Members"), gettext("names · roles")}
    ]
  end

  defp role_label(:org_admin), do: gettext("Org-admin")
  defp role_label(:member), do: gettext("Member")

  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_user), do: "—"

  defp location(%Organization{} = organization) do
    [organization.city, organization.region, organization.postal_code, organization.country]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
    |> detail()
  end

  defp detail(nil), do: "—"
  defp detail(""), do: "—"
  defp detail(value), do: value
end
