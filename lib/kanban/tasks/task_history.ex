defmodule Kanban.Tasks.TaskHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_history" do
    field :type, Ecto.Enum, values: [:creation, :move]
    field :from_column, :string
    field :to_column, :string

    belongs_to :task, Kanban.Tasks.Task

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(task_history, attrs) do
    task_history
    |> cast(attrs, [:type, :from_column, :to_column, :task_id])
    |> validate_required([:type, :task_id])
    |> validate_inclusion(:type, [:creation, :move])
    |> validate_move_columns()
    |> foreign_key_constraint(:task_id)
  end

  defp validate_move_columns(changeset) do
    type = get_field(changeset, :type)
    from_column = get_field(changeset, :from_column)
    to_column = get_field(changeset, :to_column)

    case type do
      :move ->
        changeset
        |> validate_required([:from_column, :to_column])

      :creation ->
        # For creation, from_column and to_column should be nil
        if from_column || to_column do
          add_error(changeset, :type, "creation events should not have from_column or to_column")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
