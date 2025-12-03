defmodule Kanban.Tasks.TaskHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_history" do
    field :type, Ecto.Enum, values: [:creation, :move, :priority_change, :assignment]
    field :from_column, :string
    field :to_column, :string
    field :from_priority, :string
    field :to_priority, :string

    belongs_to :task, Kanban.Tasks.Task
    belongs_to :from_user, Kanban.Accounts.User
    belongs_to :to_user, Kanban.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(task_history, attrs) do
    task_history
    |> cast(attrs, [
      :type,
      :from_column,
      :to_column,
      :from_priority,
      :to_priority,
      :from_user_id,
      :to_user_id,
      :task_id
    ])
    |> validate_required([:type, :task_id])
    |> validate_inclusion(:type, [:creation, :move, :priority_change, :assignment])
    |> validate_history_fields()
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:from_user_id)
    |> foreign_key_constraint(:to_user_id)
  end

  defp validate_history_fields(changeset) do
    type = get_field(changeset, :type)

    case type do
      :move ->
        changeset
        |> validate_required([:from_column, :to_column])
        |> validate_no_priority_fields()
        |> validate_no_user_fields()

      :priority_change ->
        changeset
        |> validate_required([:from_priority, :to_priority])
        |> validate_no_column_fields()
        |> validate_no_user_fields()

      :assignment ->
        changeset
        |> validate_no_column_fields()
        |> validate_no_priority_fields()

      :creation ->
        validate_creation_has_no_fields(changeset)

      _ ->
        changeset
    end
  end

  defp validate_creation_has_no_fields(changeset) do
    from_column = get_field(changeset, :from_column)
    to_column = get_field(changeset, :to_column)
    from_priority = get_field(changeset, :from_priority)
    to_priority = get_field(changeset, :to_priority)
    from_user_id = get_field(changeset, :from_user_id)
    to_user_id = get_field(changeset, :to_user_id)

    has_fields? =
      from_column || to_column || from_priority || to_priority || from_user_id || to_user_id

    if has_fields? do
      add_error(changeset, :type, "creation events should not have any history fields")
    else
      changeset
    end
  end

  defp validate_no_priority_fields(changeset) do
    from_priority = get_field(changeset, :from_priority)
    to_priority = get_field(changeset, :to_priority)

    if from_priority || to_priority do
      add_error(changeset, :type, "move events should not have priority fields")
    else
      changeset
    end
  end

  defp validate_no_column_fields(changeset) do
    from_column = get_field(changeset, :from_column)
    to_column = get_field(changeset, :to_column)

    if from_column || to_column do
      add_error(changeset, :type, "priority_change events should not have column fields")
    else
      changeset
    end
  end

  defp validate_no_user_fields(changeset) do
    from_user_id = get_field(changeset, :from_user_id)
    to_user_id = get_field(changeset, :to_user_id)

    if from_user_id || to_user_id do
      add_error(changeset, :type, "move and priority_change events should not have user fields")
    else
      changeset
    end
  end
end
