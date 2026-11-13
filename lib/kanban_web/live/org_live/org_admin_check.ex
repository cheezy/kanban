defmodule KanbanWeb.OrgLive.OrgAdminCheck do
  @moduledoc """
  The org-admin check every Organization console event runs before it acts.

  `KanbanWeb.UserAuth.OrgAdminGate` decides who may mount an Organization page,
  and its `handle_params` hook asks again on every patch, but neither runs on an
  event. `current_scope` is loaded once at mount and goes stale, so an org-admin
  demoted, disabled or deleted while a page is open would still hold an
  org-admin scope. `with_org_admin/3` therefore re-reads the actor from the
  database with `Kanban.Accounts.get_user/1` and their role with
  `Kanban.Organizations.org_admin?/2` on every event, and never reads the role
  from `current_scope`.

  The Organization is always `socket.assigns.organization`, which each page
  assigns from the `current_organization` the gate set from the signed-in
  user's own membership; it is never read from params.

  A refused event goes through `refuse/2`: it records a `:permission_denied`
  audit event with gate `:require_org_admin`, flashes the same translated
  message the gate does, and redirects to `/boards`. Pages also call
  `refuse/2` directly when a context write answers `{:error, :unauthorized}`.

  Two options keep the pages' own differences:

    * `:also` - a `(socket, actor -> boolean)` function run after the role
      check; `false` refuses. `KanbanWeb.OrgLive.SSO` uses it for its locked
      page and paid-access check.
    * `:on_refuse` - a `(socket -> socket)` function run on a refusal before
      the flash and redirect. `KanbanWeb.OrgLive.SCIM` uses it to clear the
      `:new_token` assign.
  """
  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Phoenix.LiveView.Socket

  @gate :require_org_admin

  @typedoc "An option to `with_org_admin/3` or `refuse/2`."
  @type option ::
          {:also, (Socket.t(), User.t() -> boolean())}
          | {:on_refuse, (Socket.t() -> Socket.t())}

  @doc """
  Runs `fun` when the socket's user is still an enabled org-admin of the
  socket's Organization, else refuses the event.

  The actor is re-read from the database on every call. A 1-arity `fun` gets
  the fresh actor; a 2-arity `fun` gets the actor and the Organization id. Its
  return value is returned unchanged. A refusal returns
  `{:noreply, refuse(socket, opts)}`.

  Accepts the `:also` and `:on_refuse` options described in the moduledoc; an
  unknown option raises `ArgumentError`.

  ## Examples

      with_org_admin(socket, fn actor -> {:noreply, assign(socket, :actor, actor)} end)

      with_org_admin(socket, fn actor, organization_id -> ... end,
        on_refuse: &assign(&1, :new_token, nil)
      )

  """
  @spec with_org_admin(
          Socket.t(),
          (User.t() -> result) | (User.t(), integer() -> result),
          [option()]
        ) :: result | {:noreply, Socket.t()}
        when result: term()
  def with_org_admin(%Socket{} = socket, fun, opts \\ [])
      when is_function(fun, 1) or is_function(fun, 2) do
    opts = validate_opts!(opts)

    case fresh_org_admin(socket, opts) do
      {:ok, actor} -> run(fun, actor, socket.assigns.organization.id)
      :error -> {:noreply, refuse(socket, opts)}
    end
  end

  @doc """
  Refuses the socket's user: records a `:permission_denied` audit event with
  gate `:require_org_admin`, runs the `:on_refuse` option, flashes the
  org-admin refusal and redirects to `/boards`.

  Accepts the same options as `with_org_admin/3`; `:also` is ignored here.

  ## Examples

      {:noreply, refuse(socket)}

      {:noreply, refuse(socket, on_refuse: &assign(&1, :new_token, nil))}

  """
  @spec refuse(Socket.t(), [option()]) :: Socket.t()
  def refuse(%Socket{} = socket, opts \\ []) do
    opts = validate_opts!(opts)

    Kanban.AuditLog.event(:permission_denied,
      user_id: socket.assigns.current_scope.user.id,
      gate: @gate
    )

    socket
    |> opts[:on_refuse].()
    |> put_flash(
      :error,
      gettext("You must be an org-admin of an Organization to access this page.")
    )
    |> redirect(to: ~p"/boards")
  end

  # The actor re-read from the database, when they are still an enabled
  # org-admin of the socket's Organization and the page's :also check passes.
  defp fresh_org_admin(socket, opts) do
    %{current_scope: %{user: %{id: id}}, organization: %{id: organization_id}} = socket.assigns

    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization_id),
         true <- opts[:also].(socket, actor) do
      {:ok, actor}
    else
      _not_an_enabled_org_admin -> :error
    end
  end

  defp run(fun, actor, _organization_id) when is_function(fun, 1), do: fun.(actor)
  defp run(fun, actor, organization_id) when is_function(fun, 2), do: fun.(actor, organization_id)

  # A misspelt option would silently drop a page's extra check, so unknown
  # keys raise rather than being ignored.
  defp validate_opts!(opts),
    do: Keyword.validate!(opts, also: &always/2, on_refuse: &Function.identity/1)

  defp always(_socket, _actor), do: true
end
