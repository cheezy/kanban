defmodule KanbanWeb.TaskLive.Form.AttachmentStaging do
  @moduledoc """
  Files staged in the new-task form (`KanbanWeb.TaskLive.FormComponent`),
  stored once the task exists.

  A new task has no id until `Kanban.Tasks.create_task/2` returns, so the form
  only stages files in its `:task_attachments` LiveView upload and stores them
  afterwards, on the task the server created:

    * `allow/3` sets up the upload for a new task when the viewer may upload
      on an unlocked board, and records which of three states the form shows
      (`:open`, `:locked` or `:hidden`). It is safe to call on every update,
      because a re-render of the board must not drop staged files.
    * `field/1` renders the staged field, or the inline `KanbanWeb.LockedFeature`
      prompt on a free board while plans are enforced.
    * `cancel/2` removes one staged file.
    * `store_staged/3` re-checks the board's plan and stores every finished
      entry through `KanbanWeb.TaskLive.AttachmentUploads`, which calls
      `Kanban.Attachments.create_attachment/4` and so authorizes the viewer
      and checks each file again.
    * `put_failure_flash/2` names the files that could not be stored; the
      task is kept either way.

  A failed save stores nothing: entries are only consumed by `store_staged/3`,
  so they stay staged for the next attempt. The edit form does not stage at
  all; it mounts `KanbanWeb.TaskLive.AttachmentsComponent`, which stores and
  deletes at once. Nothing here touches the Repo.
  """

  use KanbanWeb, :html

  import Phoenix.LiveView, only: [cancel_upload: 3, put_flash: 3]

  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Policy
  alias Kanban.Plans
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.Components.AttachmentItems

  @upload :task_attachments

  @doc "The name of the form's LiveView upload."
  @spec upload_name() :: atom()
  def upload_name, do: @upload

  @doc """
  Assigns `:attachment_staging` for `board` and the form's `action`, and
  allows the upload when it is `:open`:

    * `:open` — a new task on an unlocked board, for a viewer who may upload.
    * `:locked` — the viewer may upload, but the board's plan does not include
      attachments.
    * `:hidden` — the edit form, or a viewer who may not upload.

  The upload is allowed once and never re-allowed, so files staged before a
  re-render survive it.
  """
  @spec allow(Phoenix.LiveView.Socket.t(), map(), atom()) :: Phoenix.LiveView.Socket.t()
  def allow(socket, board, action) do
    state = state(socket.assigns[:current_scope], board, action)

    socket
    |> assign(:attachment_staging, state)
    |> maybe_allow_upload(state)
  end

  defp state(scope, %{id: board_id} = board, :new_task) when is_integer(board_id) do
    cond do
      not Policy.can_upload?(scope, board_id) -> :hidden
      Plans.board_unlocked?(board) -> :open
      true -> :locked
    end
  end

  defp state(_scope, _board, _action), do: :hidden

  defp maybe_allow_upload(socket, :open) do
    if upload_allowed?(socket),
      do: socket,
      else: AttachmentUploads.allow(socket, @upload, auto_upload: false)
  end

  defp maybe_allow_upload(socket, _state), do: socket

  @doc "`true` when the form's upload is registered on `socket` and not disallowed."
  @spec upload_allowed?(Phoenix.LiveView.Socket.t()) :: boolean()
  def upload_allowed?(socket), do: AttachmentUploads.upload_allowed?(socket, @upload)

  @doc "Cancels the staged entry `ref`; an unknown ref changes nothing."
  @spec cancel(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def cancel(socket, ref) when is_binary(ref) do
    if upload_allowed?(socket) and
         Enum.any?(socket.assigns.uploads[@upload].entries, &(&1.ref == ref)) do
      cancel_upload(socket, @upload, ref)
    else
      socket
    end
  end

  def cancel(socket, _ref), do: socket

  @doc """
  Stores every finished staged file on `task`, the task `Kanban.Tasks.create_task/2`
  just returned, and returns `{socket, failed}`, `failed` being
  `[{filename, reason}]`.

  The board's plan is checked again first; when it no longer includes
  attachments every finished file is cancelled and reported as failed.
  Files are stored in the order they were chosen, and a staged file that
  never finished uploading is reported as failed with its LiveView error.
  With nothing staged it does nothing.
  """
  @spec store_staged(Phoenix.LiveView.Socket.t(), term(), Task.t()) ::
          {Phoenix.LiveView.Socket.t(), [{String.t(), term()}]}
  def store_staged(socket, scope, %Task{id: task_id} = task) when is_integer(task_id) do
    # Read before storing: the modal closes after the save, so an entry that
    # never finished (refused by LiveView, or still uploading) would vanish.
    unfinished = unfinished_failures(socket)

    {socket, failed} =
      case finished_entries(socket) do
        [] -> {socket, []}
        done -> store_finished(socket, scope, task, done)
      end

    {socket, failed ++ unfinished}
  end

  defp store_finished(socket, scope, task, done) do
    case Plans.check_board(socket.assigns.board, :attachments, surface: :live_view) do
      :ok ->
        result = AttachmentUploads.store_entries(socket, @upload, scope, %{task: task})
        {socket, result.failed}

      {:error, reason} ->
        socket = Enum.reduce(done, socket, &cancel_upload(&2, @upload, &1.ref))
        {socket, Enum.map(done, &{&1.client_name, reason})}
    end
  end

  defp finished_entries(socket) do
    if upload_allowed?(socket),
      do: AttachmentUploads.finished_entries(socket, @upload),
      else: []
  end

  defp unfinished_failures(socket) do
    if upload_allowed?(socket),
      do: AttachmentUploads.unfinished_failures(socket, @upload),
      else: []
  end

  @doc """
  Puts an error flash naming each file in `failed` and why it was not
  stored. With nothing failed the socket is returned unchanged.
  """
  @spec put_failure_flash(Phoenix.LiveView.Socket.t(), [{String.t(), term()}]) ::
          Phoenix.LiveView.Socket.t()
  def put_failure_flash(socket, []), do: socket

  def put_failure_flash(socket, failed) when is_list(failed),
    do: put_flash(socket, :error, failure_message(failed))

  @doc "One translated sentence per file that could not be stored."
  @spec failure_message([{String.t(), term()}]) :: String.t()
  def failure_message(failed) when is_list(failed) do
    Enum.map_join(failed, " ", &AttachmentUploads.failure_sentence/1)
  end

  @doc """
  What holds the new-task form's save while files are staged, as
  `KanbanWeb.TaskLive.AttachmentUploads.store_blocker/2` decides it. A new
  task holds no files yet, so its room is the whole per-task limit; `nil`
  unless the field is `:open` with an upload.
  """
  @spec blocker(atom(), term()) :: nil | :errors | {:over_room, non_neg_integer()}
  def blocker(:open, %Phoenix.LiveView.UploadConfig{} = upload),
    do: AttachmentUploads.store_blocker(upload, Limits.max_files_per_task())

  def blocker(_state, _upload), do: nil

  @doc """
  The new-task form's Attachments field: a drop zone with a file input and
  the staged files, or the inline locked prompt. `upload` is the form's
  upload config and is only read when `state` is `:open`.
  """
  attr :state, :atom, required: true, values: [:open, :locked, :hidden]
  attr :upload, :any, default: nil
  attr :target, :any, default: nil

  def field(assigns) do
    ~H"""
    <fieldset
      :if={@state != :hidden}
      id="task-attachments"
      data-attachment-staging={@state}
      class="fieldset mb-2"
    >
      <span class="label mb-1">{gettext("Attachments")}</span>
      <div :if={@state == :open && @upload}>
        <label
          for={@upload.ref}
          phx-drop-target={@upload.ref}
          class="bg-base-100"
          style="display: flex; align-items: center; gap: 8px; padding: 10px 12px; border: 1px dashed var(--line-input); border-radius: 8px; cursor: pointer; font-size: 12.5px; color: var(--ink-2);"
        >
          <.icon name="hero-paper-clip" class="w-4 h-4" />
          <span>{gettext("Attach files")}</span>
          <.live_file_input upload={@upload} class="sr-only" />
        </label>
        <AttachmentItems.upload_entries
          upload={@upload}
          target={@target}
          cancel_event="cancel-attachment"
        />
        <p
          :if={message = AttachmentUploads.blocked_message(blocker(@state, @upload))}
          id="task-attachments-blocked"
          class="upload-error"
          role="status"
          style="margin: 8px 0 0; font-size: 12px; color: var(--st-blocked);"
        >
          {message}
        </p>
      </div>
      <KanbanWeb.LockedFeature.locked_feature
        :if={@state == :locked}
        feature={:attachments}
        variant={:inline}
        id="task-attachments-lock"
      />
    </fieldset>
    """
  end
end
