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
  """
  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Kanban.Accounts.Scope
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
  `current_organization`; otherwise records the refusal and halts with a
  redirect to `/boards`.
  """
  @spec authorize_mount(Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def authorize_mount(socket) do
    scope = socket.assigns[:current_scope]

    case org_admin_membership(scope) do
      %OrganizationMember{organization: organization} ->
        {:cont, Phoenix.Component.assign(socket, :current_organization, organization)}

      nil ->
        Kanban.AuditLog.event(:permission_denied, user_id: user_id(scope), gate: @gate)

        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, refusal_message())
          |> Phoenix.LiveView.redirect(to: ~p"/boards")

        {:halt, socket}
    end
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
