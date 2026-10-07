defmodule Kanban.Tasks.TaskComment do
  use Ecto.Schema
  import Ecto.Changeset

  @content_max_length 10_000

  schema "task_comments" do
    field :content, :string
    field :author_agent_name, :string
    field :edited_at, :utc_datetime
    field :mentioned_user_ids, {:array, :integer}, default: []

    belongs_to :task, Kanban.Tasks.Task
    belongs_to :author, Kanban.Accounts.User, foreign_key: :author_user_id

    timestamps()
  end

  @doc """
  Maximum number of characters a comment's `content` may hold.
  """
  def content_max_length, do: @content_max_length

  @doc """
  D111: `:task_id` is NOT cast from `attrs` — it is set server-side on the struct
  (`%TaskComment{task_id: task.id}`) by the caller. This makes the comment's
  authorship-of-scope structurally un-forgeable: a client-supplied `task_id` can
  never redirect a comment to a task on another board, even if a future caller
  forgets to overwrite it. `validate_required` still asserts the struct carries a
  `task_id`.

  The same rule covers authorship: `:author_user_id`, `:author_agent_name` and
  `:mentioned_user_ids` are server-set fields that live on the struct and are
  never cast, so a client cannot post a comment impersonating another user or
  agent. `:content` is capped at `content_max_length/0` characters.
  """
  def changeset(task_comment, attrs) do
    task_comment
    |> cast(attrs, [:content])
    |> validate_required([:content, :task_id])
    |> validate_length(:content, max: @content_max_length)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:author_user_id)
  end
end
