defmodule KanbanWeb.Admin.OrganizationLive.Show do
  @moduledoc """
  Site-admin detail page for one Organization: its details (read-only, with a
  link to the edit form), its org-admins and members, an Appoint org-admin
  form and a Remove action for each org-admin.

  Only a site admin appoints or removes an org-admin (D2). Every event
  re-reads the actor and the Organization from the database before calling
  `Kanban.Organizations`, which checks the actor again itself, so an admin
  disabled or demoted after this socket mounted cannot change anything.

  The appoint form is the only way to make someone an org-admin: there is no
  per-member promote control, and there is no delete-organization control.
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
  alias KanbanWeb.Admin.OrganizationLive.Form

  # Postgres bigint is the upper bound: Integer.parse/1 accepts any numeral,
  # and Repo.get/2 raises on one that overflows the column, so an id is
  # range-checked before the lookup rather than rescued.
  @max_bigint 9_223_372_036_854_775_807

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :appoint_form, appoint_form())}
  end

  # The actor is re-read here exactly as the events re-read it, so an admin
  # disabled or demoted since the session loaded them is treated like an
  # unknown id. get_organization/2 alone would not do that: it also returns the
  # Organization to one of its org-admins, whatever their admin status.
  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    with %User{} = actor <- authorized_actor(socket),
         %Organization{} = organization <- fetch_organization(id, actor) do
      {:noreply,
       socket
       |> assign(:page_title, organization.name)
       |> assign_organization(organization)}
    else
      nil -> {:noreply, organization_not_found(socket)}
    end
  end

  @impl true
  def handle_event("appoint", params, socket) do
    email = appoint_email(params)

    with_organization(socket, fn organization, actor ->
      actor
      |> Organizations.appoint_org_admin_by_email(organization, email, login_urls())
      |> respond_to_appoint(email, organization, socket)
    end)
  end

  @impl true
  def handle_event("remove", %{"user-id" => user_id}, socket) do
    with_organization(socket, fn organization, actor ->
      case fetch_user(user_id) do
        %User{} = user ->
          actor
          |> Organizations.remove_org_admin(organization, user)
          |> respond_to_remove(organization, socket)

        nil ->
          {:noreply,
           socket |> replace_flash(:error, error_message(:not_found)) |> refresh(organization)}
      end
    end)
  end

  # A tampered payload without a user id cannot name anyone to remove.
  @impl true
  def handle_event("remove", _params, socket),
    do: {:noreply, replace_flash(socket, :error, error_message(:not_found))}

  @doc """
  Maps a refusal from `Kanban.Organizations` to the flash message shown to the
  site admin on this page.
  """
  @spec error_message(term()) :: String.t()
  def error_message(:unauthorized), do: Form.error_message(:unauthorized)

  def error_message(:already_in_another_organization),
    do: gettext("That user already belongs to another Organization. Nothing was changed.")

  def error_message(:user_disabled),
    do: gettext("That account is disabled. Enable it before appointing it as an org-admin.")

  def error_message(:last_org_admin),
    do:
      gettext(
        "You cannot remove the last org-admin while the Organization has other members. Appoint another org-admin first."
      )

  def error_message(:not_found),
    do: gettext("That person is no longer an org-admin of this Organization.")

  def error_message(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :email),
      do: gettext("Enter a valid email address. Nothing was changed."),
      else: Form.error_message(:unknown)
  end

  def error_message(_reason), do: Form.error_message(:unknown)

  @doc """
  Maps a refusal from `Kanban.Organizations.appoint_org_admin_by_email/4` to
  its flash message. `:not_found` there means the Organization or the account
  vanished mid-appointment, not that an org-admin is gone, so it gets the
  generic message rather than the Remove path's wording.
  """
  @spec appoint_error_message(term()) :: String.t()
  def appoint_error_message(:not_found), do: Form.error_message(:unknown)
  def appoint_error_message(reason), do: error_message(reason)

  # Every event re-resolves BOTH the actor and the Organization from the
  # database; the assigns from mount are a UI hint, never the authority.
  defp with_organization(socket, fun) do
    case authorized_actor(socket) do
      nil ->
        {:noreply, replace_flash(socket, :error, error_message(:unauthorized))}

      actor ->
        case Organizations.get_organization(socket.assigns.organization.id, actor) do
          %Organization{} = organization -> fun.(organization, actor)
          nil -> {:noreply, organization_not_found(socket)}
        end
    end
  end

  defp respond_to_appoint({:ok, _member}, _email, organization, socket) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Org-admin appointed."))
     |> assign(:appoint_form, appoint_form())
     |> refresh(organization)}
  end

  defp respond_to_appoint({:error, reason}, email, organization, socket) do
    {:noreply,
     socket
     |> replace_flash(:error, appoint_error_message(reason))
     |> assign(:appoint_form, appoint_form(email))
     |> refresh(organization)}
  end

  defp respond_to_remove({:ok, _member}, organization, socket) do
    {:noreply,
     socket
     |> replace_flash(:info, gettext("Org-admin removed."))
     |> refresh(organization)}
  end

  defp respond_to_remove({:error, reason}, organization, socket) do
    {:noreply,
     socket
     |> replace_flash(:error, error_message(reason))
     |> refresh(organization)}
  end

  defp assign_organization(socket, organization) do
    socket
    |> assign(:organization, organization)
    |> assign(:members, Organizations.list_members(organization))
  end

  defp refresh(socket, organization), do: assign_organization(socket, organization)

  # Every message replaces the one before it, so an earlier error never stays
  # on screen beside (or after) the success that follows it.
  defp replace_flash(socket, kind, message),
    do: socket |> clear_flash() |> put_flash(kind, message)

  defp organization_not_found(socket) do
    socket
    |> replace_flash(:error, gettext("Organization not found."))
    |> push_navigate(to: ~p"/admin/organizations")
  end

  defp appoint_form(email \\ ""), do: to_form(%{"email" => email}, as: :appoint)

  # A tampered payload can drop the "appoint" key or send a non-string email;
  # both are treated as an empty email, which the context rejects as invalid.
  defp appoint_email(%{"appoint" => %{"email" => email}}) when is_binary(email), do: email
  defp appoint_email(_params), do: ""

  # The links in the confirmation and password-reset emails a newly provisioned
  # org-admin receives, as functions of the encoded token.
  defp login_urls do
    [
      confirmation_url: &url(~p"/users/confirm/#{&1}"),
      reset_password_url: &url(~p"/users/reset-password/#{&1}")
    ]
  end

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

  # Both lookups return nil rather than raising for a malformed, out-of-range
  # or unknown id.
  defp fetch_organization(id, actor) do
    case parse_id(id) do
      nil -> nil
      int_id -> Organizations.get_organization(int_id, actor)
    end
  end

  defp fetch_user(id) do
    case parse_id(id) do
      nil -> nil
      int_id -> Accounts.get_user(int_id)
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id
  defp parse_id(_id), do: nil

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

  defp org_admin?(%{role: :org_admin}), do: true
  defp org_admin?(_member), do: false
end
