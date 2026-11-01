defmodule KanbanWeb.TaskLive.Components.AttachmentItems do
  @moduledoc """
  Function components for attachments, shared by the task view's Attachments
  section, the comment thread and the task form:

    * `attachment_list/1` — the stored files, each with a type icon, its
      name, size, uploader and age, a download link and an optional delete
      button. A png, jpeg, gif or webp attachment shows a thumbnail instead of
      the icon, and clicking it opens a lightbox with the full image.
    * `upload_entries/1` — the files staged in a LiveView upload, each with
      a type icon (or a `live_img_preview/1` thumbnail for a valid png, jpeg,
      gif or webp entry), its progress, a cancel button and any translated
      error.

  They render only what they are given: which attachments to list and who may
  delete each one are decided by the caller, through `Kanban.Attachments`.
  Downloads go through the authenticated `/attachments/:id/download` route
  and thumbnails through `/attachments/:id/preview`, which re-checks access
  and serves only the four raster types inline; no storage key or storage URL
  is ever rendered. Whether a stored attachment gets a thumbnail is decided by
  its server-stored content type (`KanbanWeb.AttachmentResponse.inline_image?/1`),
  never by its filename, so SVG, HTML and PDF files always keep their icon.

  The lightbox opens and closes with `Phoenix.LiveView.JS` commands only (no
  server round trip and no JS hook), so every host gets it without handling
  an event. It stays inside the attachment row, and so inside the task modal's
  `[data-modal-container]`, which keeps a backdrop click from reaching the
  modal's click-away handler. It deliberately binds no Escape key: the task
  modal binds Escape on the window, and keeping that behaviour wins.
  """

  use KanbanWeb, :html

  alias Kanban.Accounts.User
  alias KanbanWeb.AttachmentResponse
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
          :if={!thumbnail?(attachment)}
          name={icon_for(attachment.content_type)}
          class="w-5 h-5 shrink-0"
        />
        <.thumbnail
          :if={thumbnail?(attachment)}
          attachment={attachment}
          lightbox_id={lightbox_id(@dom_prefix, attachment)}
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
        <.lightbox
          :if={thumbnail?(attachment)}
          attachment={attachment}
          id={lightbox_id(@dom_prefix, attachment)}
        />
      </li>
    </ul>
    """
  end

  attr :attachment, :map, required: true
  attr :lightbox_id, :string, required: true

  defp thumbnail(assigns) do
    ~H"""
    <%!-- The class replaces <.button>'s default btn classes, so the image fills the bare 40px square. --%>
    <.button
      type="button"
      id={"#{@lightbox_id}-open"}
      class="attachment-thumbnail"
      phx-click={show_lightbox(@lightbox_id)}
      aria-haspopup="dialog"
      aria-controls={@lightbox_id}
      aria-label={gettext("Open preview of %{name}", name: @attachment.filename)}
      style="flex-shrink: 0; width: 40px; height: 40px; padding: 0; overflow: hidden; cursor: zoom-in; border: 1px solid var(--line); border-radius: 6px; background: var(--color-base-200);"
    >
      <img
        src={~p"/attachments/#{@attachment.id}/preview"}
        alt={@attachment.filename}
        loading="lazy"
        width="40"
        height="40"
        style="display: block; width: 40px; height: 40px; object-fit: cover;"
      />
    </.button>
    """
  end

  attr :attachment, :map, required: true
  attr :id, :string, required: true

  defp lightbox(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden"
      role="dialog"
      aria-modal="true"
      aria-label={gettext("Preview of %{name}", name: @attachment.filename)}
      style="position: fixed; inset: 0; z-index: 60; align-items: center; justify-content: center; padding: 24px;"
    >
      <div
        id={"#{@id}-backdrop"}
        class="bg-base-200/90"
        phx-click={hide_lightbox(@id)}
        aria-hidden="true"
        style="position: absolute; inset: 0; cursor: zoom-out;"
      />
      <.focus_wrap
        id={"#{@id}-panel"}
        class="bg-base-100"
        style="position: relative; max-width: 100%; max-height: 100%; padding: 12px; border: 1px solid var(--line); border-radius: 12px; box-shadow: 0 10px 30px var(--color-base-300);"
      >
        <div
          id={"#{@id}-content"}
          style="display: flex; flex-direction: column; gap: 10px;"
        >
          <div style="display: flex; align-items: center; gap: 8px;">
            <.button
              type="button"
              id={"#{@id}-close"}
              class="btn btn-ghost btn-xs"
              phx-click={hide_lightbox(@id)}
              style="color: var(--ink-2);"
            >
              {gettext("Close")}
            </.button>
            <span
              class="truncate"
              title={@attachment.filename}
              style="flex: 1; min-width: 0; font-size: 13px; font-weight: 500; color: var(--ink);"
            >
              {@attachment.filename}
            </span>
            <.link
              href={~p"/attachments/#{@attachment.id}/download"}
              class="btn btn-ghost btn-xs"
              style="color: var(--ink-2);"
            >
              {gettext("Download")}
            </.link>
          </div>
          <img
            src={~p"/attachments/#{@attachment.id}/preview"}
            alt={@attachment.filename}
            loading="lazy"
            style="display: block; max-width: min(90vw, 1200px); max-height: 80vh; object-fit: contain; margin: 0 auto;"
          />
        </div>
      </.focus_wrap>
    </div>
    """
  end

  @doc """
  The JS that opens the lightbox `id` and moves focus to its first control,
  the Close button. Focus goes to the first control inside `<id>-content`,
  past the `focus_wrap` sentinel that keeps Tab inside the dialog.
  """
  @spec show_lightbox(String.t()) :: JS.t()
  def show_lightbox(id) when is_binary(id) do
    JS.show(to: "##{id}", display: "flex")
    |> JS.focus_first(to: "##{id}-content")
  end

  @doc """
  The JS that closes the lightbox `id` and returns focus to the thumbnail
  that opened it.
  """
  @spec hide_lightbox(String.t()) :: JS.t()
  def hide_lightbox(id) when is_binary(id) do
    JS.hide(to: "##{id}")
    |> JS.focus(to: "##{id}-open")
  end

  @doc "The DOM id of an attachment's lightbox, unique per host through `dom_prefix`."
  @spec lightbox_id(String.t(), %{id: term()}) :: String.t()
  def lightbox_id(dom_prefix, %{id: id}), do: "#{dom_prefix}-attachment-#{id}-lightbox"

  @doc """
  True when a stored attachment gets a thumbnail: its server-stored content
  type is png, jpeg, gif or webp. Stored types are already lower-cased, and
  the filename is never consulted.
  """
  @spec thumbnail?(term()) :: boolean()
  def thumbnail?(%{content_type: content_type}),
    do: AttachmentResponse.inline_image?(content_type)

  def thumbnail?(_attachment), do: false

  @doc """
  True when a staged upload entry gets a `live_img_preview/1` thumbnail: it
  is valid and its client type is png, jpeg, gif or webp. The preview is drawn
  in the browser from the user's own file, so the client type only decides
  whether to try; what is stored is still checked on the server.
  """
  @spec staged_preview?(term()) :: boolean()
  def staged_preview?(%{valid?: true, client_type: client_type}) when is_binary(client_type),
    do: client_type |> String.downcase() |> AttachmentResponse.inline_image?()

  def staged_preview?(_entry), do: false

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
          <.live_img_preview
            :if={staged_preview?(entry)}
            entry={entry}
            alt={entry.client_name}
            width="40"
            height="40"
            style="flex-shrink: 0; width: 40px; height: 40px; object-fit: cover; border: 1px solid var(--line); border-radius: 6px;"
          />
          <.icon
            :if={!staged_preview?(entry)}
            name={icon_for(entry.client_type && String.downcase(entry.client_type))}
            class="w-5 h-5 shrink-0"
          />
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
