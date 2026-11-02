defmodule KanbanWeb.ArchiveLive.RowWithMenu do
  @moduledoc """
  One row of the archive page (`KanbanWeb.ArchiveLive.Index`) with its kebab
  action menu and, when the task has files, a disclosure listing them.

  The files are read-only here: each has Download, and the thumbnail and
  lightbox for an image, but no Delete. An archived task's files can be
  deleted again once the task is restored. The parent LiveView loads them
  through `Kanban.Attachments.list_attachments_by_task/3` and passes an empty
  list when the viewer may not see them or the board's plan hides them.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskLive.Components.AttachmentItems

  @doc """
  Renders an archived row plus its action menu overlay. Passing the
  `toggle_*` attrs makes the row's leading cell render a chevron (a goal's
  own row); omitting them renders a plain archived row. `attachments` are
  the task's files, task-level and comment-level together.
  """
  attr :task, :map, required: true
  attr :menu_open_for, :string, default: nil
  attr :can_modify, :boolean, default: false
  attr :toggle_event, :string, default: nil
  attr :toggle_group_key, :string, default: nil
  attr :expanded, :boolean, default: true
  attr :attachments, :list, default: []

  def row_with_menu(assigns) do
    ~H"""
    <div data-archive-row-wrapper style="position: relative;">
      <KanbanWeb.ArchiveRow.archive_row
        task={@task}
        on_action_menu="open_archive_menu"
        toggle_event={@toggle_event}
        toggle_group_key={@toggle_group_key}
        expanded={@expanded}
      />

      <div
        :if={@menu_open_for == to_string(@task.id)}
        data-archive-row-menu
        phx-click-away="close_archive_menu"
        style={[
          "position: absolute; right: 14px; top: 32px; z-index: 10;",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 6px;",
          "box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);",
          "display: flex; flex-direction: column;",
          "min-width: 160px;"
        ]}
      >
        <button
          :if={@can_modify}
          type="button"
          data-archive-menu-restore
          phx-click="unarchive"
          phx-value-id={@task.id}
          style={[
            "padding: 8px 12px; border: 0; background: transparent;",
            "text-align: left; font: inherit; font-size: 12px;",
            "color: var(--ink); cursor: pointer;"
          ]}
        >
          {gettext("Restore")}
        </button>

        <button
          :if={@can_modify}
          type="button"
          data-archive-menu-delete
          phx-click="delete"
          phx-value-id={@task.id}
          data-confirm={gettext("Are you sure you want to delete this task?")}
          style={[
            "padding: 8px 12px; border: 0; background: transparent;",
            "text-align: left; font: inherit; font-size: 12px;",
            "color: var(--st-blocked); cursor: pointer;",
            "border-top: 1px solid var(--line);"
          ]}
        >
          {gettext("Delete forever")}
        </button>

        <span
          :if={not @can_modify}
          data-archive-menu-read-only
          style="padding: 8px 12px; font-size: 11.5px; color: var(--ink-3); font-style: italic;"
        >
          {gettext("Read-only access")}
        </span>
      </div>

      <details
        :if={@attachments != []}
        id={"archive-files-#{@task.id}"}
        data-archive-row-files
        style={[
          "padding: 6px 14px 10px 136px;",
          "border-bottom: 1px solid var(--line); background: var(--surface);"
        ]}
      >
        <summary style="cursor: pointer; display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink-2);">
          <.icon name="hero-paper-clip" class="w-4 h-4" />
          {ngettext("1 file", "%{count} files", length(@attachments))}
        </summary>
        <div style="margin-top: 8px; max-width: 640px;">
          <AttachmentItems.attachment_list
            attachments={@attachments}
            dom_prefix={"archive-files-#{@task.id}"}
          />
        </div>
      </details>
    </div>
    """
  end
end
