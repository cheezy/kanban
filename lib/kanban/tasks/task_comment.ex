defmodule Kanban.Tasks.TaskComment do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @content_max_length 10_000
  @agent_name_max_length 255

  schema "task_comments" do
    field :content, :string
    field :author_agent_name, :string
    field :edited_at, :utc_datetime
    field :mentioned_user_ids, {:array, :integer}, default: []

    # Set by Kanban.Tasks.Comments on a successful create or update: the
    # members this write newly mentions (on create, every stored id; on an
    # edit, the ids that were not mentioned before). Never persisted, never cast.
    field :newly_mentioned_user_ids, {:array, :integer}, virtual: true, default: []

    belongs_to :task, Kanban.Tasks.Task
    belongs_to :author, Kanban.Accounts.User, foreign_key: :author_user_id

    timestamps()
  end

  @doc """
  Maximum number of codepoints a comment's `content` may hold.
  """
  def content_max_length, do: @content_max_length

  @doc """
  D111: `:task_id` is NOT cast from `attrs` — it is set server-side on the struct
  (`%TaskComment{task_id: task.id}`) by the caller. This makes the comment's
  authorship-of-scope structurally un-forgeable: a client-supplied `task_id` can
  never redirect a comment to a task on another board, even if a future caller
  forgets to overwrite it. `validate_required` still asserts the struct carries a
  `task_id`.

  The same rule covers authorship: `:author_user_id`, `:author_agent_name`,
  `:mentioned_user_ids` and the virtual `:newly_mentioned_user_ids` are
  server-set fields that are never cast (they live on the struct, or for
  `:author_agent_name` come through `put_author_agent_name/2`), so a client
  cannot post a comment impersonating another user or agent, or mention
  someone the server did not resolve. `:content` is capped at `content_max_length/0`
  codepoints (so a run of combining marks cannot store megabytes), may not
  contain a NUL character, and is blank when it holds only whitespace and
  invisible format characters.
  """
  def changeset(task_comment, attrs) do
    task_comment
    |> cast(attrs, [:content])
    |> validate_required([:content, :task_id])
    |> validate_length(:content, max: @content_max_length, count: :codepoints)
    |> validate_change(:content, &validate_storable_text/2)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:author_user_id)
  end

  @doc """
  Puts the server-resolved `author_agent_name` on a create changeset and
  checks it fits the column (at most #{@agent_name_max_length} characters), so
  an over-long name is a changeset error rather than a database error. The
  value comes from the server's attribution step, never from `attrs`.
  """
  def put_author_agent_name(changeset, agent_name) do
    changeset
    |> put_change(:author_agent_name, agent_name)
    |> validate_length(:author_agent_name, max: @agent_name_max_length, count: :codepoints)
    |> validate_change(:author_agent_name, &validate_storable_text/2)
  end

  # PostgreSQL text cannot hold a NUL character, so one is a changeset error
  # rather than a database error. Text made only of whitespace and invisible
  # format characters (zero-width spaces, bidi marks) is blank. Whitespace-only
  # text is left to validate_required, which already reports it.
  defp validate_storable_text(field, value) when is_binary(value) do
    cond do
      String.contains?(value, <<0>>) -> [{field, "is invalid"}]
      String.trim(value) == "" -> []
      String.replace(value, ~r/[\s\p{Cf}]/u, "") == "" -> [{field, "can't be blank"}]
      true -> []
    end
  end

  defp validate_storable_text(_field, _value), do: []
end
