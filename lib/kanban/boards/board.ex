defmodule Kanban.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :description, :string
    field :ai_optimized_board, :boolean, default: false

    field :field_visibility, :map,
      default: %{
        "acceptance_criteria" => true,
        "complexity" => false,
        "context" => false,
        "key_files" => false,
        "verification_steps" => false,
        "technical_notes" => false,
        "observability" => false,
        "error_handling" => false,
        "technology_requirements" => false,
        "pitfalls" => false,
        "out_of_scope" => false,
        "required_capabilities" => false
      }

    field :user_access, Ecto.Enum, values: [:owner, :read_only, :modify], virtual: true

    has_many :board_users, Kanban.Boards.BoardUser
    has_many :columns, Kanban.Columns.Column
    many_to_many :users, Kanban.Accounts.User, join_through: Kanban.Boards.BoardUser

    timestamps()
  end

  @doc false
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :field_visibility])
    |> validate_required([:name])
    |> validate_length(:name, min: 5, max: 50)
    |> validate_length(:description, max: 255)
    |> validate_field_visibility()
  end

  defp validate_field_visibility(changeset) do
    case get_change(changeset, :field_visibility) do
      nil ->
        changeset

      visibility when is_map(visibility) ->
        required_keys = [
          "acceptance_criteria",
          "complexity",
          "context",
          "key_files",
          "verification_steps",
          "technical_notes",
          "observability",
          "error_handling",
          "technology_requirements",
          "pitfalls",
          "out_of_scope",
          "required_capabilities"
        ]

        if Enum.all?(required_keys, &Map.has_key?(visibility, &1)) do
          changeset
        else
          add_error(changeset, :field_visibility, "missing required field visibility keys")
        end

      _ ->
        add_error(changeset, :field_visibility, "must be a map")
    end
  end
end
