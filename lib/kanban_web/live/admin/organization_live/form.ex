defmodule KanbanWeb.Admin.OrganizationLive.Form do
  @moduledoc """
  Site-admin screen that creates an Organization (`:new`) or edits its name,
  address and contact (`:edit`) through `Kanban.Organizations`.

  The actor is re-read from the database when an Organization is loaded (by
  `Kanban.Organizations.get_organization/2`) and on every save (here), so an
  admin disabled or demoted after their socket mounted cannot read or write
  anything. There is no delete action.
  """
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares this
  # hook, but re-declaring it here keeps the LiveView admin-only even if the
  # route is ever moved out of that live_session.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization

  # Postgres bigint is the upper bound: Integer.parse/1 accepts any numeral,
  # and Repo.get/2 raises on one that overflows the column, so the id is
  # range-checked before the lookup rather than rescued.
  @max_bigint 9_223_372_036_854_775_807

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="px-4 py-8 sm:px-6 lg:px-8">
        <div class="mb-6">
          <.link
            navigate={~p"/admin/organizations"}
            id="back-to-organizations"
            class="flex items-center gap-2 text-[var(--ink-2)] hover:text-[var(--stride-orange)]"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Back to organizations")}
          </.link>
        </div>

        <.header>
          {@page_title}
          <:subtitle>
            {gettext("Only site admins create Organizations and edit their details.")}
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="organization-form"
          class="mt-8 max-w-2xl"
          phx-change="validate"
          phx-submit="save"
        >
          <section aria-labelledby="organization-details-heading">
            <h2
              id="organization-details-heading"
              class="mb-2 text-lg font-semibold text-base-content"
            >
              {gettext("Details")}
            </h2>
            <.input field={@form[:name]} type="text" label={gettext("Name")} />
          </section>

          <section aria-labelledby="organization-address-heading" class="mt-8">
            <h2
              id="organization-address-heading"
              class="mb-2 text-lg font-semibold text-base-content"
            >
              {gettext("Address")}
            </h2>
            <.input field={@form[:address_line1]} type="text" label={gettext("Address line 1")} />
            <.input field={@form[:address_line2]} type="text" label={gettext("Address line 2")} />
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input field={@form[:city]} type="text" label={gettext("City")} />
              <.input field={@form[:region]} type="text" label={gettext("Region")} />
              <.input field={@form[:postal_code]} type="text" label={gettext("Postal code")} />
              <.input field={@form[:country]} type="text" label={gettext("Country")} />
            </div>
          </section>

          <section aria-labelledby="organization-contact-heading" class="mt-8">
            <h2
              id="organization-contact-heading"
              class="mb-2 text-lg font-semibold text-base-content"
            >
              {gettext("Contact")}
            </h2>
            <.input field={@form[:contact_name]} type="text" label={gettext("Contact name")} />
            <.input field={@form[:contact_phone]} type="tel" label={gettext("Contact phone")} />
            <.input field={@form[:contact_email]} type="email" label={gettext("Contact email")} />
          </section>

          <div class="mt-8 flex items-center gap-4">
            <.button variant="primary" phx-disable-with={gettext("Saving...")}>
              {submit_label(@live_action)}
            </.button>
            <.link
              navigate={~p"/admin/organizations"}
              class="text-sm text-[var(--ink-2)] hover:text-base-content"
            >
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("validate", params, socket) do
    changeset =
      Organizations.change_organization(socket.assigns.organization, organization_params(params))

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("save", params, socket) do
    case authorized_actor(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, error_message(:unauthorized))}

      actor ->
        socket
        |> save(socket.assigns.live_action, organization_params(params), actor)
        |> respond(socket)
    end
  end

  @doc """
  Returns the path of `organization`'s site-admin detail page.

  Built as a plain string because that page's route
  (`/admin/organizations/:id`, `Admin.OrganizationLive.Show`) arrives in a
  later task; a `~p` path to a route that does not exist yet fails
  `compile --warning-as-errors`. Switch to `~p` once the route exists.
  """
  @spec detail_path(Organization.t()) :: String.t()
  def detail_path(%Organization{id: id}) when is_integer(id), do: "/admin/organizations/#{id}"

  @doc """
  Maps a refusal from `Kanban.Organizations` to the flash message shown to the
  site admin.
  """
  @spec error_message(term()) :: String.t()
  def error_message(:unauthorized), do: gettext("You must be an admin to perform this action.")

  def error_message(%Ecto.Changeset{}),
    do: gettext("The Organization could not be saved. Check the errors below.")

  def error_message(_reason), do: gettext("Something went wrong. Please try again.")

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("New Organization"))
    |> assign_organization(%Organization{})
  end

  # get_organization/2 re-reads the actor's row itself, so an admin disabled or
  # demoted since the session loaded them gets nil, the same as an unknown id.
  defp apply_action(socket, :edit, %{"id" => id}) do
    apply_edit(socket, fetch_organization(id, socket.assigns.current_scope.user))
  end

  defp apply_edit(socket, %Organization{} = organization) do
    socket
    |> assign(:page_title, gettext("Edit Organization"))
    |> assign_organization(organization)
  end

  defp apply_edit(socket, nil) do
    socket
    |> put_flash(:error, gettext("Organization not found."))
    |> push_navigate(to: ~p"/admin/organizations")
  end

  defp assign_organization(socket, organization) do
    socket
    |> assign(:organization, organization)
    |> assign(:form, to_form(Organizations.change_organization(organization)))
  end

  defp save(_socket, :new, attrs, actor), do: Organizations.create_organization(attrs, actor)

  defp save(socket, :edit, attrs, actor),
    do: Organizations.update_organization(socket.assigns.organization, attrs, actor)

  defp respond({:ok, organization}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, saved_message(socket.assigns.live_action))
     |> push_navigate(to: detail_path(organization))}
  end

  defp respond({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, error_message(changeset))
     |> assign(:form, to_form(changeset, action: :validate))}
  end

  defp respond({:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, error_message(reason))}
  end

  defp saved_message(:new), do: gettext("Organization created.")
  defp saved_message(:edit), do: gettext("Organization updated.")

  defp submit_label(:new), do: gettext("Create Organization")
  defp submit_label(:edit), do: gettext("Save Organization")

  # A tampered payload can drop the "organization" key or send a non-map in
  # its place; both are treated as no changes rather than crashing.
  defp organization_params(%{"organization" => attrs}) when is_map(attrs), do: attrs
  defp organization_params(_params), do: %{}

  # current_scope is loaded at mount and never refreshed, so it still claims
  # admin for someone since disabled or demoted. Re-read the actor from the
  # database, and pass that fresh struct to the context.
  defp authorized_actor(socket) do
    with %{user: %{id: id}} <- socket.assigns[:current_scope],
         %User{type: :admin, disabled_at: nil} = actor <- Accounts.get_user(id) do
      actor
    else
      _ -> nil
    end
  end

  # Returns nil rather than raising for a malformed, out-of-range or unknown id.
  defp fetch_organization(id, actor) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> fetch_organization(int_id, actor)
      _ -> nil
    end
  end

  defp fetch_organization(id, actor) when is_integer(id) and id > 0 and id <= @max_bigint,
    do: Organizations.get_organization(id, actor)

  defp fetch_organization(_id, _actor), do: nil
end
