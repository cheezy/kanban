defmodule KanbanWeb.WorkspaceLive.ExportCard do
  @moduledoc """
  The Export section of `KanbanWeb.WorkspaceLive.Settings` (W2222): the
  button that requests a workspace export and the list of recent exports with
  their status and, once ready, a download link.

  Rendered only for an org-admin of the workspace's Organization. The event it
  sends (`request_export`) is handled, and re-authorized, by the settings
  LiveView, and the download link is re-authorized by
  `KanbanWeb.WorkspaceExportController`.
  """
  use KanbanWeb, :html

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias KanbanWeb.WorkspaceLive.Exports

  attr :exports, :list, required: true

  def export_card(assigns) do
    assigns = assign(assigns, :active?, Exports.active?(assigns.exports))

    ~H"""
    <.settings_card
      id="export"
      tab={:export}
      title={gettext("Export this workspace")}
      hint={
        gettext(
          "A zip archive of this workspace's boards, columns, labels, tasks, comments, history and memberships, for a backup or to move the workspace to another Stride instance. It is prepared in the background; its status and download link appear below. Archives are kept for %{days} days.",
          days: Export.retention_days()
        )
      }
    >
      <div class="flex flex-col gap-3 @md:flex-row @md:items-center">
        <.button
          id="request-workspace-export"
          type="button"
          variant="primary"
          class="btn btn-primary btn-sm"
          phx-click="request_export"
          phx-disable-with={gettext("Requesting...")}
          disabled={@active?}
        >
          {gettext("Request export")}
        </.button>
        <p
          :if={@active?}
          id="workspace-export-in-progress"
          role="status"
          style="margin: 0; font-size: 12.5px; color: var(--ink-2);"
        >
          {gettext("An export is being prepared. You can leave this page; it keeps going.")}
        </p>
      </div>
    </.settings_card>

    <.settings_card
      id="workspace-export-list"
      title={gettext("Recent exports")}
      hint={gettext("Only org-admins of this workspace's Organization can download an archive.")}
      compact
    >
      <p
        :if={@exports == []}
        id="no-workspace-exports"
        style="margin: 0; padding: 10px 0; font-size: 13px; color: var(--ink-2);"
      >
        {gettext("No exports yet.")}
      </p>
      <ul id="workspace-exports" style="list-style: none; margin: 0; padding: 0;">
        <li
          :for={export <- @exports}
          id={"workspace-export-#{export.id}"}
          class="flex flex-col gap-2 @md:flex-row @md:items-center @md:gap-4"
          style="padding: 10px 0; border-bottom: 1px solid var(--line);"
        >
          <span
            class="@md:flex-1 min-w-0"
            style="font-size: 12.5px; color: var(--ink-2); overflow-wrap: anywhere;"
          >
            {export_details(export)}
            <span
              :if={export.status == "failed"}
              id={"workspace-export-error-#{export.id}"}
              style="display: block; margin-top: 2px; color: var(--ink);"
            >
              {Exports.error_label(export.error)}
            </span>
          </span>
          <span
            id={"workspace-export-status-#{export.id}"}
            class="@md:w-24 @md:flex-shrink-0"
            style="font-size: 12px; font-family: var(--font-mono); color: var(--ink-2);"
          >
            {Exports.status_label(export.status)}
          </span>
          <div class="flex flex-wrap items-center gap-2 @md:flex-shrink-0 @md:w-24">
            <.link
              :if={Exports.downloadable?(export)}
              id={"download-workspace-export-#{export.id}"}
              href={~p"/workspace/exports/#{export.id}/download"}
              class="btn btn-soft btn-sm"
            >
              {gettext("Download")}
            </.link>
          </div>
        </li>
      </ul>
    </.settings_card>
    """
  end

  defp export_details(%WorkspaceExport{} = export) do
    gettext("By %{requester} · requested %{requested} · %{size} · expires %{expires}",
      requester: requester(export),
      requested: date(export.inserted_at),
      size: Exports.format_bytes(export.byte_size),
      expires: date(export.expires_at)
    )
  end

  defp requester(%WorkspaceExport{requested_by: %{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp requester(%WorkspaceExport{requested_by: %{email: email}}) when is_binary(email), do: email
  defp requester(_export), do: "—"

  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp date(_none), do: "—"
end
