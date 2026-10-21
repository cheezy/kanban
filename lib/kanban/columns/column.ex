defmodule Kanban.Columns.Column do
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.ChangesetText

  schema "columns" do
    field :name, :string
    field :position, :integer
    field :wip_limit, :integer, default: 0

    belongs_to :board, Kanban.Boards.Board
    has_many :tasks, Kanban.Tasks.Task

    timestamps()
  end

  @doc false
  def changeset(column, attrs) do
    column
    # :board_id is intentionally NOT cast — it is the tenant-scoping field and
    # must be set server-side from the trusted %Board{} (see Columns.create_column/3),
    # never from request params. Casting it would allow a cross-tenant write
    # (column[board_id]=<other board>) via the LiveView save handler. The
    # foreign_key_constraint below still guards DB-level integrity.
    |> cast(attrs, [:name, :position, :wip_limit])
    |> ChangesetText.validate_storable([:name])
    |> validate_required([:name, :position])
    # The column is varchar(255); a longer name raised at the database.
    |> validate_length(:name, max: 255, count: :codepoints)
    |> validate_number(:wip_limit, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :position])
  end
end
