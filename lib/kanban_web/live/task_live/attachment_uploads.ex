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
    * `display_name/1` and `failure_sentence/1` show a file the browser named
      under the name it would be stored as, never under the raw client name.
    * `upload_allowed?/2` says whether an upload is usable right now.

  Nothing here touches the Repo or decides who may upload.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [upload_errors: 1, upload_errors: 2]
  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entry: 3]

  alias Kanban.Attachments
  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.Filename
  alias Kanban.Attachments.Limits
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.WorkspaceLive.Exports

  @doc """
  `true` when the upload `name` is registered on `socket` and not disallowed.

  `Phoenix.LiveView.disallow_upload/2` keeps the config under its name and
  only marks it `allowed?: false`, so the key alone cannot tell a usable
  upload from a revoked one. A host that read the key would never allow the
  upload again after a revocation, and the file input it then rendered would
  carry a ref the LiveView no longer knows, which crashes the view when the
  browser sends a file.
  """
  @spec upload_allowed?(Phoenix.LiveView.Socket.t(), atom()) :: boolean()
  def upload_allowed?(socket, name) when is_atom(name) do
    match?(%{allowed?: true}, Map.get(socket.assigns[:uploads] || %{}, name))
  end

  @doc """
  The name to show for a file the browser named `client_name`: the name
  `Kanban.Attachments.Filename.sanitize/1` would store, or a translated
  placeholder when nothing is left of it.

  The client name is whatever the browser sent, so it can carry bidi
  overrides that make `invoice\\u202Egpj.txt` read as `invoicetxt.jpg`,
  invisible characters, a directory or thousands of characters. Showing it
  raw would let the staged row and the failure message disagree with the
  name the file is stored and downloaded under.
  """
  @spec display_name(term()) :: String.t()
  def display_name(client_name) do
    case Filename.sanitize(client_name) do
      {:ok, name} -> name
      {:error, _reason} -> gettext("unnamed file")
    end
  end

  @doc """
  The translated sentence for one file that could not be stored, from a
  `{client_name, reason}` pair as `store_entries/4` returns them.
  """
  @spec failure_sentence({term(), term()}) :: String.t()
  def failure_sentence({client_name, reason}) do
    gettext("Could not upload %{filename}: %{reason}",
      filename: display_name(client_name),
      reason: error_message(reason)
    )
  end

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
  callback returns. Entries are stored in the order the user chose them.
  Entries still uploading, or refused by LiveView, are left in place;
  `unfinished_failures/2` names them.

  Returns `%{stored: [attachment], failed: [{client_name, reason}]}`.
  """
  @spec store_entries(Phoenix.LiveView.Socket.t(), atom(), term(), map()) :: %{
          stored: [Kanban.Attachments.TaskAttachment.t()],
          failed: [{String.t(), term()}]
        }
  def store_entries(socket, name, scope, %{task: %Task{}} = attrs) do
    results =
      socket
      |> finished_entries(name)
      |> Enum.map(fn entry ->
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
  The finished entries of the upload `name`, in the order the user chose
  them, or `[]` when it is not registered.

  `Phoenix.LiveView.uploaded_entries/2` lists them newest first, so storing
  from it reversed the user's order on the task, and under a file-count or
  quota limit kept the last files chosen instead of the first.
  """
  @spec finished_entries(Phoenix.LiveView.Socket.t(), atom()) :: [
          Phoenix.LiveView.UploadEntry.t()
        ]
  def finished_entries(socket, name), do: entries(socket, name, & &1.done?)

  @doc """
  `[{client_name, reason}]` for every entry of the upload `name` that never
  finished: the entry's own LiveView error (`:too_large`, `:not_accepted`),
  else the upload's (`:too_many_files`), else `:incomplete`.

  A form that closes once it saves (the new-task form) reports these, or
  the files would vanish while the save reports success.
  """
  @spec unfinished_failures(Phoenix.LiveView.Socket.t(), atom()) :: [{String.t(), term()}]
  def unfinished_failures(socket, name) do
    case socket.assigns[:uploads][name] do
      nil ->
        []

      conf ->
        for entry <- entries(socket, name, &(not &1.done?)),
            do: {entry.client_name, unfinished_reason(conf, entry)}
    end
  end

  defp unfinished_reason(conf, entry) do
    case upload_errors(conf, entry) ++ upload_errors(conf) do
      [reason | _rest] -> reason
      [] -> :incomplete
    end
  end

  defp entries(socket, name, keep?) do
    case socket.assigns[:uploads][name] do
      %{entries: entries} -> Enum.filter(entries, keep?)
      _unregistered -> []
    end
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
  What stops an upload's staged files from being stored as they are, given
  the `room` the task has left (counting every file on it, a comment's
  included): `:errors` when any entry or the upload has an error, which makes
  LiveView's client drop the form's submit without a word; `{:over_room,
  room}` when more valid files are staged than fit, which the server would
  refuse after they had uploaded; else `nil`.
  """
  @spec store_blocker(Phoenix.LiveView.UploadConfig.t(), non_neg_integer()) ::
          nil | :errors | {:over_room, non_neg_integer()}
  def store_blocker(%{errors: [_ | _]}, _room), do: :errors

  def store_blocker(%{entries: entries}, room) when is_integer(room) do
    if Enum.count(entries, &(&1.valid? and not &1.cancelled?)) > room,
      do: {:over_room, room}
  end

  @doc "The translated line that says what to do about a `store_blocker/2` result."
  @spec blocked_message(nil | :errors | {:over_room, non_neg_integer()}) :: String.t() | nil
  def blocked_message(nil), do: nil

  def blocked_message(:errors),
    do: gettext("Cancel the files marked with an error to upload the others.")

  def blocked_message({:over_room, 0}),
    do: gettext("This task has no room for more files. Delete a file or cancel the staged ones.")

  def blocked_message({:over_room, room}) do
    join_sentences([
      ngettext(
        "This task has room for %{count} more file.",
        "This task has room for %{count} more files.",
        room
      ),
      gettext("Cancel some files to upload the rest.")
    ])
  end

  @doc "The line shown in place of the drop zone on a task that holds its limit."
  @spec full_message() :: String.t()
  def full_message do
    join_sentences([error_message(:too_many_files), gettext("Delete a file to upload another.")])
  end

  # Japanese and Chinese end a sentence with a full-width full stop and no
  # space after it.
  @unspaced_locales ~w(ja zh)

  @doc """
  Joins translated sentences, dropping `nil`s, the way the current locale
  spaces them: a space between sentences, none in Japanese or Chinese. Use
  it wherever separately translated sentences are shown as one message.
  """
  @spec join_sentences([String.t() | nil]) :: String.t()
  def join_sentences(sentences) when is_list(sentences) do
    sentences |> Enum.reject(&is_nil/1) |> Enum.join(sentence_gap())
  end

  defp sentence_gap do
    [language | _region] = KanbanWeb.Gettext |> Gettext.get_locale() |> String.split(["_", "-"])
    if language in @unspaced_locales, do: "", else: " "
  end

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
    count = Limits.max_files_per_task()

    ngettext(
      "A task can hold at most %{count} file.",
      "A task can hold at most %{count} files.",
      count
    )
  end

  def error_message(:empty), do: gettext("This file is empty.")

  def error_message(:unreadable), do: gettext("This file could not be read. Please try again.")

  # The file does not fit in what is left, which can be more than nothing;
  # a board outside an Organization has a quota too.
  def error_message(:quota_exceeded),
    do: gettext("There is not enough attachment storage left for this file.")

  def error_message(:incomplete), do: gettext("This file did not finish uploading.")

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
