defmodule KanbanWeb.TaskLive.AttachmentUploads do
  @moduledoc """
  The LiveView side of attachment uploads, shared by every surface that takes
  files: the task view's Attachments section, comments and the task form.

    * `allow/3` registers an upload with the accept list and limits taken
      from `Kanban.Attachments`, so an operator changing them changes every
      form at once.
    * `store_entries/4` consumes the finished entries and stores each through
      `Kanban.Attachments.create_attachment/4`, which authorizes the caller
      and checks the real size and type again. The accept list and the
      LiveView limits are only a hint for the browser.
    * `error_message/1` turns a LiveView upload error or a context refusal
      into a translated sentence.

  Nothing here touches the Repo or decides who may upload.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.LiveView,
    only: [allow_upload: 3, consume_uploaded_entry: 3, uploaded_entries: 2]

  alias Kanban.Attachments
  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.Limits
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.WorkspaceLive.Exports

  @doc """
  The `:accept` list for `allow_upload/3`: every allowed content type, plus
  every allowed extension LiveView knows a MIME type for. LiveView raises on
  an extension with no MIME type (`.log`), so such an extension is accepted
  through its content type instead.
  """
  @spec accept() :: [String.t()]
  def accept do
    extensions =
      Enum.filter(ContentType.extensions(), &(&1 |> String.trim_leading(".") |> MIME.has_type?()))

    extensions ++ ContentType.allowed()
  end

  @doc """
  Registers the upload `name` on `socket` with the accept list, the per-file
  size limit and the per-task file count from `Kanban.Attachments.Limits`,
  uploading each file as soon as it is chosen. `opts` are passed to
  `allow_upload/3` and override these defaults.
  """
  @spec allow(Phoenix.LiveView.Socket.t(), atom(), keyword()) :: Phoenix.LiveView.Socket.t()
  def allow(socket, name, opts \\ []) when is_atom(name) and is_list(opts) do
    defaults = [
      accept: accept(),
      max_file_size: Limits.max_file_bytes(),
      max_entries: Limits.max_files_per_task(),
      auto_upload: true
    ]

    allow_upload(socket, name, Keyword.merge(defaults, opts))
  end

  @doc """
  Stores every finished entry of the upload `name` and returns what was
  stored and what was refused.

  `attrs` carries the `:task` and, for a comment-level file, a `:comment_id`.
  Each entry is passed to `Kanban.Attachments.create_attachment/4` inside the
  consume callback, because LiveView deletes the temporary file once the
  callback returns. Entries still uploading, or refused by LiveView, are left
  in place.

  Returns `%{stored: [attachment], failed: [{client_name, reason}]}`.
  """
  @spec store_entries(Phoenix.LiveView.Socket.t(), atom(), term(), map()) :: %{
          stored: [Kanban.Attachments.TaskAttachment.t()],
          failed: [{String.t(), term()}]
        }
  def store_entries(socket, name, scope, %{task: %Task{}} = attrs) do
    {done, _in_progress} = uploaded_entries(socket, name)

    results =
      Enum.map(done, fn entry ->
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, store_file(scope, path, entry, attrs)}
          end)

        {entry.client_name, result}
      end)

    %{
      stored: for({_name, {:ok, attachment}} <- results, do: attachment),
      failed: for({name, {:error, reason}} <- results, do: {name, reason})
    }
  end

  @doc """
  Stores one file at `path` as an attachment on `attrs.task`, named and typed
  as the browser reported it in `entry`. The size and the real type are read
  from the file by the context, never taken from the client.
  """
  @spec store_file(term(), Path.t(), map(), map()) ::
          {:ok, Kanban.Attachments.TaskAttachment.t()} | {:error, term()}
  def store_file(scope, path, entry, %{task: %Task{} = task} = attrs) do
    upload = %{
      path: path,
      filename: Map.get(entry, :client_name),
      content_type: Map.get(entry, :client_type)
    }

    Attachments.create_attachment(scope, task, upload, comment_opts(attrs))
  end

  defp comment_opts(%{comment_id: comment_id}) when is_integer(comment_id),
    do: [comment: %TaskComment{id: comment_id}]

  defp comment_opts(_attrs), do: []

  @doc """
  A translated message for a LiveView upload error (`:too_large`,
  `:not_accepted`, `:too_many_files`, `:external_client_failure`) or a
  `Kanban.Attachments` refusal.
  """
  @spec error_message(term()) :: String.t()
  def error_message(:too_large) do
    gettext("This file is larger than the %{size} limit.",
      size: Exports.format_bytes(Limits.max_file_bytes())
    )
  end

  def error_message(reason) when reason in [:not_accepted, :type_not_allowed],
    do: gettext("This file type is not allowed.")

  def error_message(:type_mismatch), do: gettext("The file contents do not match its type.")

  def error_message(:too_many_files) do
    gettext("A task can hold at most %{count} files.", count: Limits.max_files_per_task())
  end

  def error_message(:empty), do: gettext("This file is empty.")

  def error_message(:unreadable), do: gettext("This file could not be read. Please try again.")

  def error_message(:quota_exceeded),
    do: gettext("Your organization has used all of its attachment storage.")

  def error_message(:storage_unavailable),
    do: gettext("File storage is unavailable. Please try again later.")

  def error_message(:external_client_failure),
    do: gettext("The upload failed. Please try again.")

  def error_message({:plan_required, :attachments}),
    do: gettext("Attachments need a paid plan.")

  def error_message(:unauthorized),
    do: gettext("You are not allowed to change attachments on this task.")

  def error_message(:not_found), do: gettext("This file or task no longer exists.")

  def error_message(%Ecto.Changeset{}),
    do: gettext("This file could not be saved. Check its name and try again.")

  def error_message(_reason), do: gettext("The upload failed. Please try again.")
end
