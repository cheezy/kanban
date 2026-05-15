defmodule Kanban.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :description, :string
    field :ai_optimized_board, :boolean, default: false
    field :read_only, :boolean, default: false

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
    field :metrics, :map, virtual: true

    has_many :board_users, Kanban.Boards.BoardUser
    has_many :columns, Kanban.Columns.Column
    many_to_many :users, Kanban.Accounts.User, join_through: Kanban.Boards.BoardUser

    timestamps()
  end

  @doc """
  Default changeset for board mutations available to any caller with at least
  :modify access. Notably excludes `:read_only` from the cast list — that flag
  toggles whether the board is visible to non-members, so flipping it is an
  owner-only operation handled via `owner_changeset/2`.
  """
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :field_visibility])
    |> validate_required([:name])
    |> validate_length(:name, min: 5, max: 50)
    |> validate_length(:description, max: 255)
    |> validate_field_visibility()
  end

  @doc """
  Owner-only changeset. Same fields as `changeset/2` plus `:read_only`. Routed
  through by `Boards.update_board/3` after the owner check has succeeded.
  """
  def owner_changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :field_visibility, :read_only])
    |> validate_required([:name])
    |> validate_length(:name, min: 5, max: 50)
    |> validate_length(:description, max: 255)
    |> validate_field_visibility()
  end

  # Single source of truth for what field_visibility keys are allowed. Used by:
  #   * validate_field_visibility/1 below — rejects changesets containing
  #     unknown keys.
  #   * KanbanWeb.BoardLive.Show / BoardLive.Form — rejects toggle_field events
  #     whose "field" param is not in this list (closes the W401 input-
  #     validation gap where arbitrary attacker-chosen keys could be inserted).
  @toggleable_fields ~w(
    acceptance_criteria
    complexity
    context
    key_files
    verification_steps
    technical_notes
    observability
    error_handling
    technology_requirements
    pitfalls
    out_of_scope
    required_capabilities
    security_considerations
    testing_strategy
    integration_points
  )

  @doc """
  Public allow-list of valid field_visibility keys. Callers should validate
  any client-supplied field name against this list BEFORE merging into the
  field_visibility map (W401).
  """
  def toggleable_fields, do: @toggleable_fields

  defp validate_field_visibility(changeset) do
    case get_change(changeset, :field_visibility) do
      nil ->
        changeset

      visibility when is_map(visibility) ->
        case Map.keys(visibility) -- @toggleable_fields do
          [] ->
            changeset

          unknown_keys ->
            add_error(
              changeset,
              :field_visibility,
              "contains unknown keys: #{Enum.join(unknown_keys, ", ")}"
            )
        end
    end
  end
end
