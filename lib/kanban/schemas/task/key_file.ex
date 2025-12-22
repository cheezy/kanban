defmodule Kanban.Schemas.Task.KeyFile do
  @moduledoc """
  Embedded schema representing a key file that will be modified as part of a task.

  Each key file has:
  - file_path: Relative path from project root (e.g., "lib/kanban/tasks.ex")
  - note: Optional context about why this file is important (e.g., "Add claim_task/2 function")
  - position: Order in which files should be reviewed/modified
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :file_path, :string
    field :note, :string
    field :position, :integer
  end

  @doc false
  def changeset(key_file, attrs) do
    key_file
    |> cast(attrs, [:file_path, :note, :position])
    |> validate_required([:file_path, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_file_path()
  end

  defp validate_file_path(changeset) do
    if file_path = get_field(changeset, :file_path) do
      cond do
        String.starts_with?(file_path, "/") ->
          add_error(changeset, :file_path, "must be a relative path, not absolute")

        String.contains?(file_path, "..") ->
          add_error(changeset, :file_path, "must not contain .. path traversal")

        true ->
          changeset
      end
    else
      changeset
    end
  end
end
