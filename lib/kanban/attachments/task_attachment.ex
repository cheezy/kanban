defmodule Kanban.Attachments.TaskAttachment do
  @moduledoc """
  One file attached to a task, and optionally to one of the task's comments.

  The row records what the file is (`filename`, `content_type`, `byte_size`,
  `sha256`) and where its bytes live (`storage_key`, a key for
  `Kanban.Attachments.Storage`). Deleting a row by any path, including a
  cascade from its task, comment or board, queues its blob for removal
  through the `AFTER DELETE` trigger described in
  `Kanban.Attachments.BlobDeletion`. Deleting the uploader keeps the row and
  sets `uploaded_by_id` to `nil`.

  The database does not check that `comment_id` belongs to the same task as
  `task_id`; the attachments context does.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.Filename
  alias Kanban.Attachments.Limits
  alias Kanban.ChangesetText

  @type t :: %__MODULE__{}

  @sha256_format ~r/\A[0-9a-f]{64}\z/
  @mismatch "does not match the file contents"
  @head_bytes 512
  @chunk_bytes 65_536

  schema "task_attachments" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :storage_key, :string

    belongs_to :task, Kanban.Tasks.Task
    belongs_to :comment, Kanban.Tasks.TaskComment
    belongs_to :board, Kanban.Boards.Board
    belongs_to :uploaded_by, Kanban.Accounts.User

    timestamps()
  end

  @typedoc """
  The file's bytes for the content check: the bytes themselves, or a
  `{:file, path}` to read them from (an upload's temporary file).
  """
  @type contents :: binary() | {:file, Path.t()}

  @doc """
  A changeset for a new attachment.

  Only `:filename`, `:content_type`, `:byte_size` and `:sha256` are cast from
  `attrs`. `:task_id`, `:comment_id`, `:board_id`, `:uploaded_by_id` and
  `:storage_key` are server-set: the caller puts them on the struct
  (`%TaskAttachment{task_id: task.id, board_id: ..., storage_key: ...}`), so a
  client-supplied value can never attach a file to another board's task or
  point a row at someone else's blob, even if a future caller forgets to
  overwrite it. `validate_required` still asserts the struct carries
  `task_id`, `board_id` and `storage_key`.

  The checks:

    * `filename` is sanitised by `Kanban.Attachments.Filename` and must stay
      visible.
    * `content_type` is normalised by `Kanban.Attachments.ContentType`
      (inferred from the extension when it is missing, empty or
      `application/octet-stream`), must be on the allow-list, and must agree
      with the file name's extension (`ContentType.extension_matches?/2`);
      otherwise "does not match the file extension" is added to
      `content_type`.
    * `sniff`, the file's contents, must agree with `content_type`; otherwise
      "does not match the file contents" is added to `content_type`. For an
      image or a PDF the head is enough: pass the first 512 bytes (or the
      whole file when it is smaller), or `{:file, path}`. A text type has no
      signature, so it is checked over the whole body: pass every byte (a
      binary whose size equals `byte_size`), or `{:file, path}` for a file
      of that size. A shorter binary gets "must be checked against the whole
      file", and a file that cannot be read gets "could not be checked".
    * `byte_size` is at least 1 and at most `Limits.max_file_bytes/0`.
    * `sha256` is exactly 64 lowercase hexadecimal characters.
  """
  @spec create_changeset(t(), map(), contents()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = attachment, attrs, sniff)
      when is_binary(sniff) or (is_tuple(sniff) and elem(sniff, 0) == :file) do
    attachment
    |> cast(attrs, [:filename, :content_type, :byte_size, :sha256])
    |> validate_required([:filename, :byte_size, :sha256, :task_id, :board_id, :storage_key])
    |> put_filename()
    |> ChangesetText.validate_visible([:filename])
    |> put_content_type()
    |> validate_sniff(sniff)
    |> validate_number(:byte_size,
      greater_than: 0,
      less_than_or_equal_to: Limits.max_file_bytes()
    )
    |> validate_format(:sha256, @sha256_format, message: "must be 64 lowercase hex characters")
    |> check_constraint(:byte_size, name: :byte_size_positive)
    |> unique_constraint(:storage_key)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:uploaded_by_id)
  end

  defp put_filename(changeset) do
    case fetch_change(changeset, :filename) do
      {:ok, name} -> put_sanitized_filename(changeset, Filename.sanitize(name))
      :error -> changeset
    end
  end

  defp put_sanitized_filename(changeset, {:ok, name}), do: put_change(changeset, :filename, name)

  defp put_sanitized_filename(changeset, {:error, _reason}),
    do: add_error(changeset, :filename, "is invalid")

  defp put_content_type(changeset) do
    filename = get_field(changeset, :filename)
    declared = get_field(changeset, :content_type)
    type = ContentType.normalize(declared, filename)

    cond do
      not ContentType.allowed?(type) ->
        add_error(changeset, :content_type, "is not an allowed type")

      not ContentType.extension_matches?(type, filename) ->
        add_error(changeset, :content_type, "does not match the file extension")

      true ->
        put_change(changeset, :content_type, type)
    end
  end

  defp validate_sniff(changeset, sniff) do
    if Keyword.has_key?(changeset.errors, :content_type) do
      changeset
    else
      check_contents(changeset, get_field(changeset, :content_type), sniff)
    end
  end

  defp check_contents(changeset, type, sniff) do
    case read_head(sniff) do
      {:ok, head} -> check_head(changeset, type, head, sniff)
      :error -> add_error(changeset, :content_type, "could not be checked")
    end
  end

  defp check_head(changeset, type, head, sniff) do
    cond do
      not ContentType.matches?(type, head) -> add_error(changeset, :content_type, @mismatch)
      ContentType.text?(type) -> check_text_body(changeset, sniff)
      true -> changeset
    end
  end

  defp check_text_body(changeset, sniff) do
    case text_body(sniff, get_field(changeset, :byte_size)) do
      :ok -> changeset
      :binary -> add_error(changeset, :content_type, @mismatch)
      :partial -> add_error(changeset, :content_type, "must be checked against the whole file")
      :unreadable -> add_error(changeset, :content_type, "could not be checked")
    end
  end

  defp read_head(sniff) when is_binary(sniff), do: {:ok, sniff}

  defp read_head({:file, path}) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, head} when is_binary(head) -> {:ok, head}
      {:ok, :eof} -> {:ok, ""}
      _error -> :error
    end
  end

  defp read_head(_sniff), do: :error

  defp text_body(sniff, size) when is_binary(sniff) and byte_size(sniff) == size,
    do: text_verdict([sniff])

  defp text_body(sniff, _size) when is_binary(sniff), do: :partial

  defp text_body({:file, path}, size) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size}} ->
        text_verdict(File.stream!(path, @chunk_bytes))

      {:ok, %File.Stat{type: :regular}} ->
        :partial

      _other ->
        :unreadable
    end
  end

  defp text_verdict(chunks), do: if(ContentType.text_body?(chunks), do: :ok, else: :binary)
end
