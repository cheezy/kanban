defmodule KanbanWeb.TaskLive.CommentThreadComponent do
  @moduledoc """
  The task comment thread: the list of comments plus the composer and the
  inline edit and delete controls, shared by the task view modal
  (`KanbanWeb.TaskLive.ViewComponent`) and the task edit form
  (`KanbanWeb.TaskLive.FormComponent`) so the two can no longer diverge.

  Each comment shows its author's avatar and name ("Unknown" for legacy rows
  with no author; the agent name plus "via <user>" for comments an agent
  posted through the API), a relative time, and an "edited" marker once
  `edited_at` is set. A `@[Name](user:ID)` mention of a current board member
  renders as a chip showing that member's current name; any other token stays
  plain text. Each row is rendered by
  `KanbanWeb.TaskLive.Components.CommentRow`.

  The composer and the edit form use
  `KanbanWeb.TaskLive.Components.MentionField`, whose autocomplete hook asks
  this component's `mention_search` event for up to eight
  matching board members. The reply is `%{members: [%{id: id, label: label}]}`,
  `label` being safe to place in a mention token; a viewer who is not a member
  of the task's board gets an empty list.

  Data and permissions come from `Kanban.Tasks.list_comment_thread/2`, which
  resolves the viewer's board access once. The rendered controls are a hint
  only: every event calls the authorizing `Kanban.Tasks` comment functions,
  so a forged event for a control that was never rendered is still refused.

  ## Attachments

  Files staged in the composer are stored on the comment the server creates,
  only once it is saved. Each comment lists its files. Its author may
  remove one while editing it, and the board's owner (an org-admin counts)
  may remove any comment's file without editing; a deleted comment's files
  go with it through the foreign key cascade. A locked board shows the inline
  `KanbanWeb.LockedFeature`. The helpers live in
  `KanbanWeb.TaskLive.CommentAttachments`.

  ## Assigns

    * `id` — use `dom_id/2`, which keeps the two hosts' ids distinct.
    * `task_id` — the task whose comments to show.
    * `current_scope` — the viewer's scope; `nil` renders read-only.

  ## Live refresh

  `refresh/1` re-reads the thread in every host that may have it open. The
  board LiveView calls it on a `:comment_changed` or `:attachment_changed`
  broadcast, and on a membership change, which can change the board's plan.
  A refresh keeps an open composer draft and an open edit form, unless the
  comment being edited is gone or no longer editable.
  """
  use KanbanWeb, :live_component

  alias Kanban.Attachments
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.SectionHead
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.CommentAttachments
  alias KanbanWeb.TaskLive.Components.AttachmentItems
  alias KanbanWeb.TaskLive.Components.CommentRow
  alias KanbanWeb.TaskLive.Components.MentionField

  @hosts [:view, :form]

  # The most suggestions one mention_search reply carries.
  @mention_limit 8

  @doc """
  The component id for the thread mounted in `host` (`:view` or `:form`).
  """
  def dom_id(host, task_id) when host in @hosts, do: "comment-thread-#{host}-#{task_id}"

  @doc """
  The DOM id of one comment's row inside the thread whose component id is
  `thread_id`. See `KanbanWeb.TaskLive.Components.CommentRow.comment_dom_id/2`.
  """
  defdelegate comment_dom_id(thread_id, comment), to: CommentRow

  @doc """
  Asks every mounted thread for the task in `payload` to reload its comments.

  Accepts the `:comment_changed` broadcast payload (`%{task_id: id}`) or a
  bare task id. Must be called from the LiveView process hosting the
  components; a thread that is not mounted is skipped by LiveView.
  """
  def refresh(%{task_id: task_id}), do: refresh(task_id)

  def refresh(task_id) when is_integer(task_id) do
    Enum.each(@hosts, fn host ->
      send_update(__MODULE__, id: dom_id(host, task_id), refresh: true)
    end)
  end

  def refresh(_payload), do: :ok

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load_thread(socket)}

  @impl true
  def update(%{id: id, task_id: task_id} = assigns, socket) do
    same_task? = Map.get(socket.assigns, :task_id) == task_id

    {:ok,
     socket
     |> assign(:id, id)
     |> assign(:task_id, task_id)
     |> assign(:current_scope, Map.get(assigns, :current_scope))
     |> reset_or_keep_drafts(same_task?)
     |> load_thread()}
  end

  # A re-render for the same task must not wipe a draft or an open edit.
  defp reset_or_keep_drafts(socket, true) do
    socket
    |> assign_new(:comment_form, fn -> new_comment_form(socket.assigns.id) end)
    |> assign_new(:editing_id, fn -> nil end)
    |> assign_new(:edit_form, fn -> nil end)
  end

  defp reset_or_keep_drafts(socket, false) do
    socket
    |> assign(:comment_form, new_comment_form(socket.assigns.id))
    |> clear_editing()
  end

  @impl true
  def handle_event("add_comment", %{"task_comment" => params}, socket) when is_map(params) do
    socket.assigns.current_scope
    |> Tasks.create_comment(task_ref(socket), params)
    |> handle_create_result(socket)
  end

  @impl true
  def handle_event("edit_comment", %{"id" => raw_id}, socket) do
    case find_entry(socket, raw_id) do
      %{can_edit: true, comment: comment} ->
        {:noreply,
         socket
         |> assign(:editing_id, comment.id)
         |> assign(:edit_form, edit_form(TaskComment.changeset(comment, %{}), socket, comment.id))}

      _not_editable ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket), do: {:noreply, clear_editing(socket)}

  # The file input needs a phx-change; the draft stays in the browser.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, CommentAttachments.cancel_entry(socket, ref)}

  # The attachment must be on the comment the viewer is editing, which only
  # its author can (CommentAttachments.find_removable/2); the plan and
  # Kanban.Attachments.delete_attachment/2 then decide again.
  @impl true
  def handle_event("remove_comment_attachment", %{"id" => raw_id}, socket) do
    with :ok <- CommentAttachments.check_plan(socket.assigns.board_id),
         {:ok, attachment} <- CommentAttachments.find_removable(socket.assigns, raw_id),
         {:ok, _deleted} <-
           Attachments.delete_attachment(socket.assigns.current_scope, attachment) do
      {:noreply, socket |> load_thread() |> notify_flash(:info, gettext("Attachment deleted"))}
    else
      {:error, reason} -> {:noreply, removal_refused(socket, reason)}
    end
  end

  # The target is the server-held editing_id, never an id from the client.
  @impl true
  def handle_event("save_comment", %{"task_comment" => params}, socket) when is_map(params) do
    case socket.assigns.editing_id do
      nil ->
        {:noreply, socket}

      editing_id ->
        socket.assigns.current_scope
        |> Tasks.update_comment(%TaskComment{id: editing_id}, params)
        |> handle_save_result(socket, editing_id)
    end
  end

  # The comment must belong to this thread, but whether the viewer may delete
  # it is decided by Tasks.delete_comment/2, not by which buttons rendered.
  @impl true
  def handle_event("delete_comment", %{"id" => raw_id}, socket) do
    case find_entry(socket, raw_id) do
      %{comment: comment} ->
        socket.assigns.current_scope
        |> Tasks.delete_comment(comment)
        |> handle_delete_result(socket)

      nil ->
        {:noreply, comment_gone(socket)}
    end
  end

  # The mention autocomplete (assets/js/hooks/mention_autocomplete.js) asks
  # for board members matching what follows an @. The board comes from the
  # server-held task id, and Tasks.search_mentionable_members/4 refuses a
  # viewer who is not a member of it, so any refusal is an empty list: the
  # reply never says why, and members cannot be enumerated from outside.
  @impl true
  def handle_event("mention_search", params, socket) do
    members =
      case Tasks.search_mentionable_members(
             socket.assigns.current_scope,
             task_ref(socket),
             mention_query(params),
             @mention_limit
           ) do
        {:ok, members} -> members
        {:error, _reason} -> []
      end

    {:reply, %{members: members}, socket}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp mention_query(%{"query" => query}) when is_binary(query), do: query
  defp mention_query(_params), do: ""

  # Staged files are stored on the server-returned comment before the reload
  # lists them; one that fails is named in a flash and the comment stays.
  # The thread scrolls on its own, so the new comment can land below the
  # visible rows; the browser is told to bring it into view (see app.js).
  defp handle_create_result({:ok, comment}, socket) do
    {socket, failed} = CommentAttachments.store(socket, comment)

    {:noreply,
     socket
     |> assign(:comment_form, new_comment_form(socket.assigns.id))
     |> load_thread()
     |> push_event("comment-thread:scroll-to", %{id: comment_dom_id(socket.assigns.id, comment)})
     |> notify_flash(:info, gettext("Comment added successfully"))
     |> notify_failed_files(CommentAttachments.failure_message(failed))}
  end

  defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, assign(socket, :comment_form, comment_form(changeset, socket.assigns.id))}

  defp handle_create_result({:error, :unauthorized}, socket) do
    {:noreply,
     notify_flash(socket, :error, gettext("You must be a board member to comment on this task"))}
  end

  defp handle_create_result({:error, :not_found}, socket),
    do: {:noreply, socket |> load_thread() |> notify_flash(:error, gettext("Task not found"))}

  defp handle_save_result({:ok, _comment}, socket, _editing_id),
    do: {:noreply, socket |> clear_editing() |> load_thread()}

  defp handle_save_result({:error, %Ecto.Changeset{} = changeset}, socket, editing_id),
    do: {:noreply, assign(socket, :edit_form, edit_form(changeset, socket, editing_id))}

  defp handle_save_result({:error, :not_found}, socket, _editing_id),
    do: {:noreply, comment_gone(socket)}

  defp handle_save_result({:error, :unauthorized}, socket, _editing_id),
    do: {:noreply, not_allowed(socket)}

  defp handle_delete_result({:ok, _comment}, socket), do: {:noreply, load_thread(socket)}
  defp handle_delete_result({:error, :not_found}, socket), do: {:noreply, comment_gone(socket)}
  defp handle_delete_result({:error, :unauthorized}, socket), do: {:noreply, not_allowed(socket)}

  defp notify_failed_files(socket, nil), do: socket
  defp notify_failed_files(socket, message), do: notify_flash(socket, :error, message)

  defp removal_refused(socket, :unauthorized), do: not_allowed(socket)

  # A vanished comment closes the edit form on reload; a gone file does not.
  defp removal_refused(socket, :not_found) do
    was_editing? = not is_nil(socket.assigns.editing_id)
    socket = load_thread(socket)

    message =
      if was_editing? and is_nil(socket.assigns.editing_id),
        do: gettext("This comment no longer exists"),
        else: gettext("This attachment no longer exists.")

    notify_flash(socket, :error, message)
  end

  defp removal_refused(socket, reason),
    do: socket |> load_thread() |> notify_flash(:error, AttachmentUploads.error_message(reason))

  defp comment_gone(socket) do
    socket
    |> clear_editing()
    |> load_thread()
    |> notify_flash(:error, gettext("This comment no longer exists"))
  end

  defp not_allowed(socket) do
    socket
    |> clear_editing()
    |> load_thread()
    |> notify_flash(:error, gettext("You are not allowed to change this comment"))
  end

  # LiveView discards a live component's own flash unless the component also
  # redirects or patches, so the message goes to the hosting LiveView, which
  # owns the flash and handles {CommentThreadComponent, {:flash, kind, message}}.
  defp notify_flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp load_thread(socket) do
    socket
    |> assign_thread(Tasks.list_comment_thread(socket.assigns.current_scope, task_ref(socket)))
    |> assign_attachments()
    |> CommentAttachments.sync_upload()
  end

  defp assign_thread(socket, {:ok, %{board_id: board_id, can_comment: can, entries: entries}}) do
    socket
    |> assign(board_id: board_id, can_comment: can, entries: entries)
    |> keep_editing_if_still_editable()
  end

  defp assign_thread(socket, {:error, :not_found}),
    do: socket |> assign(board_id: nil, can_comment: false, entries: []) |> clear_editing()

  defp assign_attachments(%{assigns: %{current_scope: scope, board_id: board_id}} = socket),
    do: assign(socket, CommentAttachments.load(scope, task_ref(socket), board_id))

  defp keep_editing_if_still_editable(%{assigns: %{editing_id: nil}} = socket), do: socket

  defp keep_editing_if_still_editable(socket) do
    editing_id = socket.assigns.editing_id

    if Enum.any?(socket.assigns.entries, &(&1.comment.id == editing_id and &1.can_edit)),
      do: socket,
      else: clear_editing(socket)
  end

  defp clear_editing(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:edit_form, nil)
  end

  defp find_entry(socket, raw_id) when is_binary(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> Enum.find(socket.assigns.entries, &(&1.comment.id == id))
      _invalid -> nil
    end
  end

  defp find_entry(_socket, _raw_id), do: nil

  defp task_ref(socket), do: %Task{id: socket.assigns.task_id}

  defp new_comment_form(id), do: comment_form(TaskComment.changeset(%TaskComment{}, %{}), id)

  defp comment_form(changeset, id), do: to_form(changeset, id: "#{id}-composer")

  defp edit_form(changeset, socket, comment_id),
    do: to_form(changeset, id: "#{socket.assigns.id}-edit-#{comment_id}")

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} data-comment-thread phx-hook="CommentAnchor">
      <SectionHead.section_head title={gettext("Comments")} count_label={count_label(@entries)} />

      <p
        :if={@entries == []}
        style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
      >
        {gettext("No comments yet")}
      </p>

      <div
        :if={@entries != []}
        style="display: flex; flex-direction: column; gap: 14px; max-height: 28rem; overflow-y: auto;"
      >
        <CommentRow.comment_row
          :for={entry <- @entries}
          entry={entry}
          editing={entry.comment.id == @editing_id}
          edit_form={@edit_form}
          target={@myself}
          dom_prefix={@id}
          attachments={Map.get(@comment_attachments, entry.comment.id, [])}
          moderate={@moderates_files?}
        />
      </div>

      <.form
        :let={f}
        :if={@can_comment}
        for={@comment_form}
        id={"#{@id}-composer"}
        phx-target={@myself}
        phx-change={@can_attach? && "validate"}
        phx-submit="add_comment"
        style="margin-top: 16px;"
      >
        <MentionField.mention_textarea
          field={f[:content]}
          label={gettext("Add a comment")}
          placeholder={gettext("Write your comment here...")}
        />
        <div :if={@can_attach? && @uploads[:comment_attachments]} style="margin-top: 8px;">
          <p
            :if={@attach_room == 0}
            id={"#{@id}-attach-full"}
            style="margin: 0; padding: 10px 12px; border: 1px dashed var(--line-input); border-radius: 8px; font-size: 12.5px; color: var(--ink-2);"
          >
            {AttachmentUploads.full_message()}
          </p>
          <label
            :if={@attach_room > 0}
            for={@uploads.comment_attachments.ref}
            phx-drop-target={@uploads.comment_attachments.ref}
            class="bg-base-100"
            style="display: flex; align-items: center; gap: 8px; padding: 10px 12px; border: 1px dashed var(--line-input); border-radius: 8px; cursor: pointer; font-size: 12.5px; color: var(--ink-2);"
          >
            <.icon name="hero-paper-clip" class="w-4 h-4" />
            <span>{gettext("Attach files")}</span>
            <.live_file_input upload={@uploads.comment_attachments} class="sr-only" />
          </label>
          <AttachmentItems.upload_entries upload={@uploads.comment_attachments} target={@myself} />
          <p
            :if={message = AttachmentUploads.blocked_message(attach_blocker(assigns))}
            id={"#{@id}-attach-blocked"}
            class="upload-error"
            role="status"
            style="margin: 8px 0 0; font-size: 12px; color: var(--st-blocked);"
          >
            {message}
          </p>
        </div>
        <div :if={@attach_locked?} style="margin-top: 8px;">
          <KanbanWeb.LockedFeature.locked_feature
            feature={:attachments}
            variant={:inline}
            id={"#{@id}-attach-lock"}
          />
        </div>
        <div style="margin-top: 8px;">
          <.button
            type="submit"
            disabled={not is_nil(attach_blocker(assigns))}
            phx-disable-with={gettext("Adding...")}
          >
            {gettext("Add Comment")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  # LiveView's client drops the post while a staged file has an error, and
  # files past the task's room would be refused after the comment exists, so
  # Add Comment waits and the composer says why (see
  # AttachmentUploads.store_blocker/2). A thread without the upload has none.
  defp attach_blocker(%{can_attach?: true, uploads: %{comment_attachments: upload}} = assigns),
    do: AttachmentUploads.store_blocker(upload, assigns.attach_room)

  defp attach_blocker(_assigns), do: nil

  defp count_label([]), do: nil
  defp count_label(entries), do: entries |> length() |> Integer.to_string()
end
