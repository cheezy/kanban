defmodule KanbanWeb.WorkspaceSwitcher do
  @moduledoc """
  The workspace switcher in the side nav (`KanbanWeb.SideNav`).

  Workspaces are paid-only (D7), so what renders depends on the scope, with no
  query here — `KanbanWeb.UserAuth` has already loaded the list into
  `current_scope.workspaces` and verified `current_scope.workspace`:

    * **A user who belongs to an Organization** gets the switcher: their
      reachable, unarchived org workspaces, never a personal one. Each entry is
      a small form that POSTs `/workspace/switch` (with the CSRF token), which
      re-checks everything on the server. A link to `/workspace/settings` shows
      when a workspace is current.
    * **A user without an Organization, while plans are enforced,** sees the
      slot rendered by `KanbanWeb.LockedFeature` for `:workspaces`.
    * **Anyone else** sees nothing.

  Hiding the switcher is never the authorization: the switch endpoint and
  workspace settings check paid access and reach themselves.
  """
  use KanbanWeb, :html

  alias Kanban.Accounts.Scope
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Plans
  alias KanbanWeb.LockedFeature

  attr :current_scope, :map, required: true

  def workspace_switcher(assigns) do
    assigns = assign(assigns, :mode, mode(assigns.current_scope))

    render_mode(assigns)
  end

  @doc """
  Returns what the switcher renders for `scope`: `:list` for a member of an
  Organization, `:locked` for anyone else while plans are enforced, and
  `:none` otherwise.
  """
  @spec mode(Scope.t() | nil) :: :list | :locked | :none
  def mode(%Scope{user: %{}, organization_membership: %OrganizationMember{}}), do: :list

  def mode(%Scope{user: %{}}) do
    if Plans.enforced?(), do: :locked, else: :none
  end

  def mode(_scope), do: :none

  defp render_mode(%{mode: :none} = assigns), do: ~H""

  defp render_mode(%{mode: :locked} = assigns) do
    ~H"""
    <div style="padding: 2px 10px 6px;">
      <LockedFeature.locked_feature feature={:workspaces} id="workspace-switcher-locked" />
    </div>
    """
  end

  defp render_mode(%{mode: :list} = assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.current_scope.workspace)
      |> assign(:workspaces, assigns.current_scope.workspaces || [])

    ~H"""
    <details id="workspace-switcher" style="padding: 0 6px 6px;">
      <summary
        aria-label={gettext("Switch workspace")}
        style={[
          "display: flex; align-items: center; gap: 6px; cursor: pointer;",
          "padding: 5px 8px; border-radius: 5px; list-style: none;",
          "background: var(--surface); box-shadow: inset 0 0 0 1px var(--line);",
          "font-size: 12px; font-weight: 600; color: var(--ink); min-width: 0;"
        ]}
      >
        <span style="display: inline-flex; color: var(--ink-3); flex-shrink: 0;">
          <.icon name="hero-rectangle-stack" class="w-3.5 h-3.5" />
        </span>
        <span
          data-workspace-current
          title={@current && @current.name}
          style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1;"
        >
          {if @current, do: @current.name, else: gettext("Choose a workspace")}
        </span>
        <span style="display: inline-flex; color: var(--ink-3); flex-shrink: 0;">
          <.icon name="hero-chevron-up-down" class="w-3.5 h-3.5" />
        </span>
      </summary>

      <div style="margin-top: 4px; display: flex; flex-direction: column; gap: 1px;">
        <p
          :if={@workspaces == []}
          style="margin: 0; padding: 5px 8px; font-size: 12px; color: var(--ink-2);"
        >
          {gettext("No workspaces yet")}
        </p>

        <.form
          :for={workspace <- @workspaces}
          for={%{}}
          as={:workspace_switch}
          action={~p"/workspace/switch"}
          method="post"
          id={"workspace-switch-#{workspace.id}"}
        >
          <input type="hidden" name="workspace_id" value={workspace.id} />
          <button
            type="submit"
            title={workspace.name}
            aria-current={if current?(workspace, @current), do: "true"}
            style={[
              "display: flex; align-items: center; gap: 6px; width: 100%;",
              "padding: 5px 8px; border-radius: 5px; border: 0; cursor: pointer;",
              "background: transparent; text-align: left; font-size: 12px;",
              "color: #{if current?(workspace, @current), do: "var(--ink)", else: "var(--ink-2)"};",
              "font-weight: #{if current?(workspace, @current), do: 600, else: 500};"
            ]}
          >
            <span style={[
              "width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0;",
              "background: #{if current?(workspace, @current), do: "var(--stride-orange)", else: "transparent"};"
            ]}></span>
            <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0;">
              {workspace.name}
            </span>
          </button>
        </.form>

        <.link
          :if={@current}
          navigate={~p"/workspace/settings"}
          style={[
            "display: flex; align-items: center; gap: 6px;",
            "padding: 5px 8px; border-radius: 5px; font-size: 12px;",
            "color: var(--ink-2); text-decoration: none;"
          ]}
        >
          <.icon name="hero-adjustments-horizontal" class="w-3.5 h-3.5" />
          {gettext("Workspace settings")}
        </.link>
      </div>
    </details>
    """
  end

  defp current?(%{id: id}, %{id: id}), do: true
  defp current?(_workspace, _current), do: false
end
