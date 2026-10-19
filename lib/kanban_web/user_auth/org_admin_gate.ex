defmodule KanbanWeb.UserAuth.OrgAdminGate do
  @moduledoc """
  The org-admin decision behind `KanbanWeb.UserAuth`'s `:require_org_admin`
  on_mount and `require_org_admin_user/2` plug.

  `KanbanWeb.UserAuth` halts unconfirmed users first, exactly as its other
  gates do, and hands every other caller here. A caller passes only when
  `current_scope.organization_membership` has role `:org_admin`. The role is
  read from the membership `KanbanWeb.UserAuth` loaded for this request or
  mount, never from params, so the Organization is always the caller's own.
  A site admin (`User.type` `:admin`) is not an org-admin and is refused like
  anyone else.

  A caller who passes gets `current_organization`: the membership's
  Organization, without its contact fields. A refused caller is redirected to
  `/boards` with a translated flash, and a `:permission_denied` audit event is
  recorded with gate `:require_org_admin`.

  on_mount runs once per mount, but paging, filtering and changing tabs patch
  the same LiveView without mounting it again. `authorize_mount/1` therefore
  attaches a `handle_params` hook that re-reads the role from the database on
  every patch, so an org-admin removed or disabled while a page is open is
  refused on their next click instead of only on their next reload.
  """
  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Kanban.Accounts.Scope
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember

  @gate :require_org_admin

  @doc """
  Returns the scope's membership when its role is `:org_admin`, else `nil`.

  ## Examples

      iex> org_admin_membership(%Scope{organization_membership: %OrganizationMember{role: :org_admin}})
      %OrganizationMember{role: :org_admin}

      iex> org_admin_membership(%Scope{organization_membership: nil})
      nil

  """
  @spec org_admin_membership(Scope.t() | nil) :: OrganizationMember.t() | nil
  def org_admin_membership(%Scope{
        organization_membership: %OrganizationMember{role: :org_admin} = membership
      }),
      do: membership

  def org_admin_membership(_scope), do: nil

  @doc """
  Continues the LiveView mount for an org-admin, assigning
  `current_organization` and attaching the `recheck_params/3` hook; otherwise
  records the refusal and halts with a redirect to `/boards`.
  """
  @spec authorize_mount(Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def authorize_mount(socket) do
    scope = socket.assigns[:current_scope]

    case org_admin_membership(scope) do
      %OrganizationMember{organization: organization} ->
        socket =
          socket
          |> Phoenix.Component.assign(:current_organization, organization)
          |> Phoenix.LiveView.attach_hook(:org_admin_recheck, :handle_params, &recheck_params/3)

        {:cont, socket}

      nil ->
        {:halt, refuse_socket(socket, scope)}
    end
  end

  @doc """
  The `handle_params` hook `authorize_mount/1` attaches: continues while the
  signed-in user is still an enabled org-admin of `current_organization`, read
  from the database rather than the scope loaded at mount; otherwise records the
  refusal and halts with a redirect to `/boards`.
  """
  @spec recheck_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def recheck_params(_params, _uri, socket) do
    %{current_scope: scope, current_organization: organization} = socket.assigns

    if Organizations.org_admin?(scope.user, organization.id),
      do: {:cont, socket},
      else: {:halt, refuse_socket(socket, scope)}
  end

  defp refuse_socket(socket, scope) do
    Kanban.AuditLog.event(:permission_denied, user_id: user_id(scope), gate: @gate)

    socket
    |> Phoenix.LiveView.put_flash(:error, refusal_message())
    |> Phoenix.LiveView.redirect(to: ~p"/boards")
  end

  @doc """
  Lets an org-admin's request through, assigning `current_organization`;
  otherwise records the refusal and halts with a redirect to `/boards`.
  """
  @spec authorize_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def authorize_conn(conn) do
    scope = conn.assigns[:current_scope]

    case org_admin_membership(scope) do
      %OrganizationMember{organization: organization} ->
        assign(conn, :current_organization, organization)

      nil ->
        Kanban.AuditLog.event(:permission_denied,
          user_id: user_id(scope),
          ip: conn.remote_ip,
          gate: @gate
        )

        conn
        |> put_flash(:error, refusal_message())
        |> redirect(to: ~p"/boards")
        |> halt()
    end
  end

  defp refusal_message,
    do: gettext("You must be an org-admin of an Organization to access this page.")

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil
end
