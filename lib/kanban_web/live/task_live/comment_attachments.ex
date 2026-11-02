defmodule KanbanWeb.TaskLive.CommentAttachments do
  @moduledoc """
  The comment-attachment side of `KanbanWeb.TaskLive.CommentThreadComponent`,
  kept here so the thread component stays small.

    * `load/3` reads every attachment on the task with one
      `Kanban.Attachments.list_task_attachments/2` call and groups the
      comment-level ones by comment (`group_by_comment/1`), so a thread costs
      the same number of queries however many comments carry files.
    * `can_attach?/2` asks `Kanban.Attachments.Policy` whether the viewer may
      attach files to comments on the board: owner and `:modify` members may,
      `:read_only` members may not.
    * `sync_upload/1`, `store/2` and `cancel_entry/2` drive the composer's
      `:comment_attachments` upload through
      `KanbanWeb.TaskLive.AttachmentUploads`. `allow_upload` is never called
      on a locked board or for a viewer who cannot attach.
    * `find_removable/2` finds an attachment the viewer may remove from the
      comment they are editing.

  Who may do what is decided by `Kanban.Attachments`; everything here is a
  hint that the context re-checks. Nothing here touches the Repo.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.LiveView, only: [cancel_upload: 3, disallow_upload: 2, uploaded_entries: 2]

  alias Kanban.Attachments
  alias Kanban.Attachments.Policy
  alias Kanban.Plans
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.AttachmentUploads

  @upload :comment_attachments

  @doc "The name of the composer's LiveView upload."
  @spec upload_name() :: atom()
  def upload_name, do: @upload

  @doc """
  Groups the result of one `Kanban.Attachments.list_task_attachments/2` call
  into a map of comment id to that comment's attachments, oldest first.
  Task-level rows (no `comment_id`) are dropped, and an error yields `%{}`.
  """
  @spec group_by_comment({:ok, list()} | {:error, term()} | list()) :: %{integer() => list()}
  def group_by_comment({:ok, attachments}), do: group_by_comment(attachments)
  def group_by_comment({:error, _reason}), do: %{}

  def group_by_comment(attachments) when is_list(attachments) do
    attachments
    |> Enum.reject(&is_nil(&1.comment_id))
    |> Enum.group_by(& &1.comment_id)
  end

  @doc """
  `true` when `Kanban.Attachments.Policy` lets the scope upload on
  `board_id`, which is what attaching a file to one's own comment needs.
  """
  @spec can_attach?(term(), integer() | nil) :: boolean()
  def can_attach?(_scope, nil), do: false

  def can_attach?(scope, board_id) when is_integer(board_id),
    do: Policy.can_upload?(scope, board_id)

  @doc """
  The thread's attachment assigns for the task on `board_id`:

    * `comment_attachments` — comment id to attachments (empty on a locked
      board, whose files the context hides).
    * `can_attach?` — the composer may take files.
    * `attach_locked?` — the viewer could attach, but the board's plan does
      not include attachments, so the composer shows the locked notice.
  """
  @spec load(term(), Task.t(), integer() | nil) :: map()
  def load(_scope, _task, nil),
    do: %{comment_attachments: %{}, can_attach?: false, attach_locked?: false}

  def load(scope, %Task{} = task, board_id) when is_integer(board_id) do
    may_attach? = can_attach?(scope, board_id)
    locked? = not Plans.board_unlocked?(board_id)

    %{
      comment_attachments: list_grouped(scope, task, locked?),
      can_attach?: may_attach? and not locked?,
      attach_locked?: may_attach? and locked?
    }
  end

  defp list_grouped(_scope, _task, true), do: %{}

  defp list_grouped(scope, task, false),
    do: scope |> Attachments.list_task_attachments(task) |> group_by_comment()

  @doc """
  Re-checks the plan for the board before anything is stored or removed.
  A thread whose task is gone has no board and gets `{:error, :not_found}`.
  """
  @spec check_plan(integer() | nil) :: :ok | {:error, term()}
  def check_plan(nil), do: {:error, :not_found}
  def check_plan(board_id), do: Plans.check_board(board_id, :attachments, surface: :live_view)

  @doc """
  Allows the composer upload once the viewer may attach, and drops it again
  when they no longer may, unless files are still staged in it (`store/2`
  then lets the context refuse them).
  """
  @spec sync_upload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync_upload(socket) do
    case {socket.assigns.can_attach?, upload_allowed?(socket)} do
      {true, false} -> AttachmentUploads.allow(socket, @upload)
      {false, true} -> maybe_disallow(socket)
      _unchanged -> socket
    end
  end

  defp maybe_disallow(socket) do
    if socket.assigns.uploads[@upload].entries == [],
      do: disallow_upload(socket, @upload),
      else: socket
  end

  @doc "`true` when the composer upload is registered on `socket` and not disallowed."
  @spec upload_allowed?(Phoenix.LiveView.Socket.t()) :: boolean()
  def upload_allowed?(socket), do: AttachmentUploads.upload_allowed?(socket, @upload)

  @doc """
  Stores the composer's finished files on `comment`, the comment the server
  just created, and returns `{socket, failed}`, `failed` being
  `[{filename, reason}]`. The task is the thread's server-held task id.

  With nothing staged it does nothing. When the plan no longer includes
  attachments, every finished file is cancelled and reported as failed.
  """
  @spec store(Phoenix.LiveView.Socket.t(), %{id: integer()}) ::
          {Phoenix.LiveView.Socket.t(), [{String.t(), term()}]}
  def store(socket, %{id: comment_id}) when is_integer(comment_id) do
    case finished_entries(socket) do
      [] -> {socket, []}
      done -> store_finished(socket, done, comment_id)
    end
  end

  defp store_finished(socket, done, comment_id) do
    case check_plan(socket.assigns.board_id) do
      :ok -> {socket, store_on_comment(socket, comment_id)}
      {:error, reason} -> refuse_finished(socket, done, reason)
    end
  end

  defp store_on_comment(socket, comment_id) do
    %{current_scope: scope, task_id: task_id} = socket.assigns
    attrs = %{task: %Task{id: task_id}, comment_id: comment_id}
    socket |> AttachmentUploads.store_entries(@upload, scope, attrs) |> Map.fetch!(:failed)
  end

  defp refuse_finished(socket, done, reason) do
    socket = Enum.reduce(done, socket, &cancel_upload(&2, @upload, &1.ref))
    {socket, Enum.map(done, &{&1.client_name, reason})}
  end

  defp finished_entries(socket) do
    if upload_allowed?(socket) do
      {done, _in_progress} = uploaded_entries(socket, @upload)
      done
    else
      []
    end
  end

  @doc "Cancels the staged entry `ref`; an unknown ref changes nothing."
  @spec cancel_entry(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def cancel_entry(socket, ref) when is_binary(ref) do
    if upload_allowed?(socket) and
         Enum.any?(socket.assigns.uploads[@upload].entries, &(&1.ref == ref)) do
      cancel_upload(socket, @upload, ref)
    else
      socket
    end
  end

  @doc """
  Finds the attachment `raw_id` among the thread's loaded rows, for removal.

  It must sit on the comment being edited (`editing_id`), and that comment's
  entry must be editable by the viewer — the author-only edit rule — so a
  forged event for any other comment is `{:error, :unauthorized}`, even from
  the board owner whom `Kanban.Attachments.delete_attachment/2` would allow.
  An id that is not loaded is `{:error, :not_found}`.
  """
  @spec find_removable(map(), term()) :: {:ok, struct()} | {:error, :not_found | :unauthorized}
  def find_removable(assigns, raw_id) when is_binary(raw_id) do
    with {id, ""} <- Integer.parse(raw_id),
         %{} = attachment <- find_loaded(assigns.comment_attachments, id) do
      if editing_editable?(assigns, attachment.comment_id),
        do: {:ok, attachment},
        else: {:error, :unauthorized}
    else
      _missing -> {:error, :not_found}
    end
  end

  def find_removable(_assigns, _raw_id), do: {:error, :not_found}

  defp find_loaded(grouped, id) do
    grouped
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == id))
  end

  defp editing_editable?(%{editing_id: comment_id, entries: entries}, comment_id)
       when is_integer(comment_id),
       do: Enum.any?(entries, &(&1.comment.id == comment_id and &1.can_edit))

  defp editing_editable?(_assigns, _comment_id), do: false

  @doc """
  One translated sentence per file that could not be stored, naming the file
  and the reason, or `nil` when every file was stored.
  """
  @spec failure_message([{String.t(), term()}]) :: String.t() | nil
  def failure_message([]), do: nil

  def failure_message(failed) when is_list(failed) do
    Enum.map_join(failed, " ", fn {filename, reason} ->
      gettext("Could not upload %{filename}: %{reason}",
        filename: filename,
        reason: AttachmentUploads.error_message(reason)
      )
    end)
  end
end
