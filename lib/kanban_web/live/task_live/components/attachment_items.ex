defmodule KanbanWeb.TaskLive.Components.AttachmentItems do
  @moduledoc """
  Function components for attachments, shared by the task view's Attachments
  section, the comment thread and the task form:

    * `attachment_list/1` — the stored files, each with a type icon, its
      name, size, uploader and age, a download link and an optional delete
      button.
    * `upload_entries/1` — the files staged in a LiveView upload, each with
      its progress, a cancel button and any translated error.

  They render only what they are given: which attachments to list and who may
  delete each one are decided by the caller, through `Kanban.Attachments`.
  Downloads go through the authenticated `/attachments/:id/download` route;
  no storage key or storage URL is ever rendered.
  """

  use KanbanWeb, :html

  alias Kanban.Accounts.User
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TimeAgo
  alias KanbanWeb.WorkspaceLive.Exports

  @doc """
  Lists `attachments`, or "No attachments yet" when there are none.

  `can_delete` is a one-argument function answering whether the viewer may
  delete an attachment; when it is `nil` no delete control is rendered. The
  delete button sends `delete_event` with `phx-value-id` to `target`.
  """
  attr :attachments, :list, required: true
  attr :dom_prefix, :string, required: true
  attr :target, :any, default: nil
  attr :can_delete, :any, default: nil
  attr :delete_event, :string, default: "delete-attachment"

  def attachment_list(assigns) do
    ~H"""
    <p
      :if={@attachments == []}
      id={"#{@dom_prefix}-empty"}
      style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
    >
      {gettext("No attachments yet")}
    </p>

    <ul
      :if={@attachments != []}
      id={"#{@dom_prefix}-list"}
      style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 8px;"
    >
      <li
        :for={attachment <- @attachments}
        id={"#{@dom_prefix}-attachment-#{attachment.id}"}
        style="display: flex; align-items: center; gap: 10px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px;"
      >
        <.icon
          name={icon_for(attachment.content_type)}
          class="w-5 h-5 shrink-0"
        />
        <div style="min-width: 0; flex: 1;">
          <div
            class="truncate"
            title={attachment.filename}
            style="font-size: 13px; font-weight: 500; color: var(--ink);"
          >
            {attachment.filename}
          </div>
          <div style="font-size: 12px; color: var(--ink-2);">
            {Exports.format_bytes(attachment.byte_size)} · {uploader_name(attachment.uploaded_by)} · {TimeAgo.format_age(
              to_utc(attachment.inserted_at),
              :coarse
            )}
          </div>
        </div>
        <.link
          href={~p"/attachments/#{attachment.id}/download"}
          class="btn btn-ghost btn-xs"
          style="color: var(--ink-2);"
        >
          {gettext("Download")}
        </.link>
        <.button
          :if={deletable?(@can_delete, attachment)}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click={@delete_event}
          phx-value-id={attachment.id}
          phx-target={@target}
          data-confirm={gettext("Are you sure you want to delete this attachment?")}
          style="color: var(--st-blocked);"
        >
          {gettext("Delete")}
        </.button>
      </li>
    </ul>
    """
  end

  @doc """
  Lists the entries staged in `upload` (a `Phoenix.LiveView.UploadConfig`)
  with a progress bar, a cancel button that sends `cancel_event` with
  `phx-value-ref` to `target`, and every error LiveView reported, translated.
  """
  attr :upload, :any, required: true
  attr :target, :any, default: nil
  attr :cancel_event, :string, default: "cancel-upload"

  def upload_entries(assigns) do
    ~H"""
    <p
      :for={error <- upload_errors(@upload)}
      class="upload-error"
      style="margin: 6px 0 0; font-size: 12px; color: var(--st-blocked);"
    >
      {AttachmentUploads.error_message(error)}
    </p>

    <ul
      :if={@upload.entries != []}
      style="margin: 8px 0 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px;"
    >
      <li
        :for={entry <- @upload.entries}
        id={"upload-entry-#{entry.ref}"}
        style="display: flex; flex-direction: column; gap: 4px;"
      >
        <div style="display: flex; align-items: center; gap: 8px;">
          <span
            class="truncate"
            title={entry.client_name}
            style="flex: 1; min-width: 0; font-size: 13px; color: var(--ink);"
          >
            {entry.client_name}
          </span>
          <span style="font-size: 12px; color: var(--ink-2);">
            {Exports.format_bytes(entry.client_size)}
          </span>
          <.button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click={@cancel_event}
            phx-value-ref={entry.ref}
            phx-target={@target}
            aria-label={gettext("Cancel upload of %{name}", name: entry.client_name)}
            style="color: var(--ink-2);"
          >
            {gettext("Cancel")}
          </.button>
        </div>
        <progress
          value={entry.progress}
          max="100"
          aria-label={gettext("Upload progress for %{name}", name: entry.client_name)}
          class="progress progress-primary w-full"
        >
          {entry.progress}%
        </progress>
        <p
          :for={error <- upload_errors(@upload, entry)}
          class="upload-error"
          style="margin: 0; font-size: 12px; color: var(--st-blocked);"
        >
          {AttachmentUploads.error_message(error)}
        </p>
      </li>
    </ul>
    """
  end

  @doc "The hero icon for a content type."
  @spec icon_for(term()) :: String.t()
  def icon_for("image/" <> _subtype), do: "hero-photo"
  def icon_for("application/pdf"), do: "hero-document"
  def icon_for("text/" <> _subtype), do: "hero-document-text"
  def icon_for("application/json"), do: "hero-document-text"

  def icon_for(type)
      when type in ["application/zip", "application/gzip", "application/x-tar"],
      do: "hero-archive-box"

  def icon_for(_type), do: "hero-paper-clip"

  @doc ~s{The uploader's name, else their email, else "Unknown" once the account is gone.}
  @spec uploader_name(term()) :: String.t()
  def uploader_name(%User{name: name}) when is_binary(name) and name != "", do: name
  def uploader_name(%User{email: email}) when is_binary(email) and email != "", do: email
  def uploader_name(_uploader), do: gettext("Unknown")

  defp deletable?(nil, _attachment), do: false

  defp deletable?(can_delete, attachment) when is_function(can_delete, 1),
    do: can_delete.(attachment) == true

  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = datetime), do: datetime
  defp to_utc(_missing), do: nil
end
