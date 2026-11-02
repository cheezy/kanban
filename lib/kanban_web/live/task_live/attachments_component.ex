defmodule KanbanWeb.TaskLive.AttachmentsComponent do
  @moduledoc """
  The task's Attachments section: the files attached to the task itself
  (comment attachments render under their comment), an upload drop zone and
  a delete control for each file the viewer may remove.

  Rights come from `Kanban.Attachments`: every board member may list and
  download, owner and modify members may upload, and the uploader or the
  board owner may delete. A free board on enforced plans shows the
  `KanbanWeb.LockedFeature` panel and nothing else. The rendered controls are
  a hint only: every event re-checks the plan and calls the authorizing
  `Kanban.Attachments` functions, so a forged event is refused. `allow_upload`
  is never called on a locked board or for a viewer who cannot upload.

  ## Assigns

    * `id` — use `dom_id/2`, which keeps each host's id distinct.
    * `task_id` — the task whose attachments to show.
    * `board_id` — the board the task is on.
    * `current_scope` — the viewer's scope; `nil` renders an empty list.

  ## Live refresh

  `refresh/1` re-reads the list in every host that may have it open. The
  board LiveView calls it when it receives an `:attachment_changed`
  broadcast. Messages for the flash go to the host LiveView as
  `{KanbanWeb.TaskLive.AttachmentsComponent, {:flash, kind, message}}`,
  because a live component cannot keep its own flash.
  """
  use KanbanWeb, :live_component

  alias Kanban.Attachments
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Policy
  alias Kanban.Plans
  alias Kanban.Tasks.Task
  alias KanbanWeb.SectionHead
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.Components.AttachmentItems

  @hosts [:view, :form]
  @upload :files

  @doc "The component id for the section mounted in `host` (`:view` or `:form`)."
  def dom_id(host, task_id) when host in @hosts, do: "attachments-#{host}-#{task_id}"

  @doc """
  Asks every mounted section for the task in `payload` to reload its list.

  Accepts the `:attachment_changed` broadcast payload (`%{task_id: id}`) or a
  bare task id. Must be called from the LiveView process hosting the
  components; a section that is not mounted is skipped by LiveView.
  """
  def refresh(%{task_id: task_id}), do: refresh(task_id)

  def refresh(task_id) when is_integer(task_id) do
    Enum.each(@hosts, fn host ->
      send_update(__MODULE__, id: dom_id(host, task_id), refresh: true)
    end)
  end

  def refresh(_payload), do: :ok

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  # The id carries the task id, so one instance only ever shows one task: a
  # re-render refreshes the list and the rights and keeps staged uploads.
  @impl true
  def update(%{id: id, task_id: task_id, board_id: board_id} = assigns, socket) do
    {:ok,
     socket
     |> assign(:id, id)
     |> assign(:task_id, task_id)
     |> assign(:board_id, board_id)
     |> assign(:current_scope, Map.get(assigns, :current_scope))
     |> load()}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("upload", _params, socket) do
    with :ok <- check_plan(socket),
         :ok <- check_can_upload(socket) do
      socket
      |> AttachmentUploads.store_entries(@upload, socket.assigns.current_scope, %{
        task: task_ref(socket)
      })
      |> handle_store_result(socket)
      |> resync_after_store()
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) when is_binary(ref) do
    with :ok <- check_plan(socket),
         {:ok, socket} <- cancel_entry(socket, ref) do
      {:noreply, socket}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => raw_id}, socket) do
    with :ok <- check_plan(socket),
         {:ok, attachment} <- find_attachment(socket, raw_id) do
      socket.assigns.current_scope
      |> Attachments.delete_attachment(attachment)
      |> handle_delete_result(socket)
    else
      {:error, :not_found} -> {:noreply, attachment_gone(socket)}
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Event results ───────────────────────────────────────────────────

  defp handle_store_result(%{stored: [], failed: []}, socket) do
    {:noreply, notify_flash(socket, :error, gettext("Choose files to upload first."))}
  end

  defp handle_store_result(%{stored: stored, failed: []}, socket) do
    {:noreply, socket |> load_after_store() |> notify_flash(:info, uploaded_message(stored))}
  end

  # A partly successful submit says what was stored before what was refused.
  defp handle_store_result(%{stored: stored, failed: failed}, socket) do
    message =
      AttachmentUploads.join_sentences([
        uploaded_message(stored) | Enum.map(failed, &AttachmentUploads.failure_sentence/1)
      ])

    {:noreply, socket |> load_after_store() |> notify_flash(:error, message)}
  end

  # LiveView drops consumed entries only after this event returns, so the
  # reload inside handle_store_result still sees them, with their upload
  # channels already stopped, and must leave the upload alone. When the store
  # left the viewer unable to upload (rights or plan lost mid-session), a
  # refresh queued now runs after the entries are gone and drops the upload
  # registration.
  defp resync_after_store({:noreply, socket} = reply) do
    if not socket.assigns.can_upload?,
      do: send_update(__MODULE__, id: socket.assigns.id, refresh: true)

    reply
  end

  defp uploaded_message([]), do: nil

  defp uploaded_message(stored),
    do: ngettext("Uploaded %{count} file.", "Uploaded %{count} files.", length(stored))

  defp handle_delete_result({:ok, _deleted}, socket) do
    {:noreply, socket |> load() |> notify_flash(:info, gettext("Attachment deleted"))}
  end

  defp handle_delete_result({:error, :not_found}, socket),
    do: {:noreply, attachment_gone(socket)}

  defp handle_delete_result({:error, reason}, socket), do: {:noreply, refuse(socket, reason)}

  defp attachment_gone(socket) do
    socket
    |> load()
    |> notify_flash(:error, gettext("This attachment no longer exists."))
  end

  # A refusal re-reads the plan and the rights, so the controls catch up
  # with whatever changed, and says why. The reason is flashed before the
  # reload, so a reload that drops staged files names them last, and that
  # more specific message is the one shown.
  defp refuse(socket, reason) do
    socket
    |> notify_flash(:error, AttachmentUploads.error_message(reason))
    |> load()
  end

  # ── Checks ──────────────────────────────────────────────────────────

  defp check_plan(socket),
    do: Plans.check_board(socket.assigns.board_id, :attachments, surface: :live_view)

  # The context authorizes again on every create; this stops a forged event
  # before it reaches an upload that was never allowed.
  defp check_can_upload(socket) do
    if socket.assigns.can_upload? and upload_allowed?(socket),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp cancel_entry(socket, ref) do
    if upload_allowed?(socket) and
         Enum.any?(socket.assigns.uploads[@upload].entries, &(&1.ref == ref)) do
      {:ok, cancel_upload(socket, @upload, ref)}
    else
      {:ok, socket}
    end
  end

  defp find_attachment(socket, raw_id) when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %{} = attachment <- Enum.find(socket.assigns.attachments, &(&1.id == id)) do
      {:ok, attachment}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp find_attachment(_socket, _raw_id), do: {:error, :not_found}

  # ── Loading ─────────────────────────────────────────────────────────

  # Every reload re-reads the plan and the rights and then syncs the upload,
  # so an upload that can no longer be used is dropped on every path (a
  # refusal, a delete, a broadcast refresh, and after a store the refresh
  # resync_after_store/1 queues), not only on an outright refusal.
  defp load(socket), do: socket |> load_after_store() |> sync_upload()

  # Re-reads the plan, the rights and the list without touching the upload;
  # see resync_after_store/1 for why a store cannot sync it yet.
  defp load_after_store(socket) do
    %{board_id: board_id, current_scope: scope} = socket.assigns
    locked? = not Plans.board_unlocked?(board_id)
    viewer = Policy.resolve(scope, board_id)

    socket
    |> assign(:locked?, locked?)
    |> assign(:viewer, viewer)
    |> assign(:can_upload?, not locked? and Policy.allowed?(viewer, :upload))
    |> assign(:members_only?, not locked? and not Policy.allowed?(viewer, :read))
    |> assign_attachments(list_attachments(socket, locked?))
  end

  # The section lists the task's own files, but the per-task limit counts
  # every file on the task, a comment's included, so the room left is taken
  # from the whole list.
  defp assign_attachments(socket, attachments) do
    socket
    |> assign(:attachments, Enum.filter(attachments, &is_nil(&1.comment_id)))
    |> assign(:room, max(Limits.max_files_per_task() - length(attachments), 0))
  end

  defp list_attachments(_socket, true), do: []

  defp list_attachments(socket, false) do
    case Attachments.list_task_attachments(socket.assigns.current_scope, task_ref(socket)) do
      {:ok, attachments} -> attachments
      {:error, _reason} -> []
    end
  end

  # allow_upload only for a viewer who may upload on an unlocked board, and
  # only once; an upload that can no longer be used is dropped.
  defp sync_upload(socket) do
    case {socket.assigns.can_upload?, upload_allowed?(socket)} do
      {true, false} -> AttachmentUploads.allow(socket, @upload)
      {false, true} -> drop_upload(socket)
      _unchanged -> socket
    end
  end

  # Files still staged when the viewer lost the right to upload (the plan
  # lapsed, or their access changed) can never be stored, and the section now
  # hides them behind the locked panel, so they are cancelled and named, as
  # the comment composer and the new-task form do. A cancelled entry whose
  # upload channel is alive is only marked cancelled and leaves when the
  # channel stops, so the upload stays registered, and never rendered, until
  # a later load finds it empty and disallows it.
  defp drop_upload(socket) do
    case socket.assigns.uploads[@upload].entries do
      [] -> disallow_upload(socket, @upload)
      entries -> entries |> Enum.reject(& &1.cancelled?) |> cancel_staged(socket)
    end
  end

  defp cancel_staged([], socket), do: socket

  defp cancel_staged(staged, socket) do
    reason = if socket.assigns.locked?, do: {:plan_required, :attachments}, else: :unauthorized

    message =
      Enum.map_join(staged, " ", &AttachmentUploads.failure_sentence({&1.client_name, reason}))

    staged
    |> Enum.reduce(socket, &cancel_upload(&2, @upload, &1.ref))
    |> notify_flash(:error, message)
  end

  defp upload_allowed?(socket), do: AttachmentUploads.upload_allowed?(socket, @upload)

  defp task_ref(socket), do: %Task{id: socket.assigns.task_id}

  # LiveView discards a live component's own flash unless the component also
  # redirects or patches, so the message goes to the hosting LiveView.
  defp notify_flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp can_delete_fun(viewer), do: &Policy.allowed?(viewer, :delete, &1)

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} data-attachments>
      <SectionHead.section_head
        title={gettext("Attachments")}
        count_label={count_label(@locked? or @members_only?, @attachments)}
      />

      <KanbanWeb.LockedFeature.locked_feature
        :if={@locked?}
        feature={:attachments}
        variant={:panel}
        id={"#{@id}-lock"}
      />

      <p
        :if={@members_only?}
        id={"#{@id}-members-only"}
        style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
      >
        {gettext("Only board members can see this task's files.")}
      </p>

      <div :if={!@locked? and !@members_only?}>
        <AttachmentItems.attachment_list
          attachments={@attachments}
          dom_prefix={@id}
          target={@myself}
          can_delete={can_delete_fun(@viewer)}
          delete_event="delete"
        />

        <form
          :if={@can_upload? && @uploads[:files]}
          id={"#{@id}-upload-form"}
          phx-change="validate"
          phx-submit="upload"
          phx-target={@myself}
          style="margin-top: 12px;"
        >
          <p
            :if={@room == 0}
            id={"#{@id}-full"}
            style="margin: 0; padding: 12px 16px; border: 1px dashed var(--line-input); border-radius: 8px; font-size: 13px; color: var(--ink-2);"
          >
            {AttachmentUploads.full_message()}
          </p>
          <label
            :if={@room > 0}
            for={@uploads.files.ref}
            phx-drop-target={@uploads.files.ref}
            class="bg-base-100"
            style="display: flex; align-items: center; justify-content: center; gap: 8px; padding: 16px; border: 1px dashed var(--line-input); border-radius: 8px; cursor: pointer; font-size: 13px; color: var(--ink-2);"
          >
            <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
            <span>{gettext("Drop files here or browse")}</span>
            <.live_file_input upload={@uploads.files} class="sr-only" />
          </label>

          <AttachmentItems.upload_entries upload={@uploads.files} target={@myself} />

          <p
            :if={
              message =
                AttachmentUploads.blocked_message(
                  AttachmentUploads.store_blocker(@uploads.files, @room)
                )
            }
            id={"#{@id}-store-blocked"}
            class="upload-error"
            role="status"
            style="margin: 8px 0 0; font-size: 12px; color: var(--st-blocked);"
          >
            {message}
          </p>

          <div style="margin-top: 8px;">
            <.button
              type="submit"
              disabled={not ready_to_store?(@uploads.files, @room)}
              phx-disable-with={gettext("Uploading...")}
            >
              {gettext("Upload files")}
            </.button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  # The button only stores finished, valid entries, so it waits for one, and
  # for nothing to block the store (see AttachmentUploads.store_blocker/2).
  defp ready_to_store?(upload, room) do
    is_nil(AttachmentUploads.store_blocker(upload, room)) and
      Enum.any?(upload.entries, &(&1.done? and &1.valid?))
  end

  defp count_label(true, _attachments), do: nil
  defp count_label(false, attachments), do: attachments |> length() |> Integer.to_string()
end
