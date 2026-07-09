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

  alias Kanban.Tasks.PathSafety

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

  # Shares the Kanban.Tasks.PathSafety predicate with the changed_files API check
  # so the two file-path boundaries cannot drift (D114). Empty / missing paths are
  # left to the schema's own required/type handling, preserving prior behavior.
  defp validate_file_path(changeset) do
    case get_field(changeset, :file_path) do
      nil -> changeset
      file_path -> apply_path_safety(changeset, PathSafety.validate(file_path))
    end
  end

  defp apply_path_safety(changeset, :ok), do: changeset

  defp apply_path_safety(changeset, {:error, :absolute}),
    do: add_error(changeset, :file_path, "must be a relative path, not absolute")

  defp apply_path_safety(changeset, {:error, :traversal}),
    do: add_error(changeset, :file_path, "must not contain .. path traversal")

  defp apply_path_safety(changeset, {:error, :null_byte}),
    do: add_error(changeset, :file_path, "must not contain a null byte")

  # :empty / :not_a_string are handled by the schema's required/type validation.
  defp apply_path_safety(changeset, {:error, _reason}), do: changeset
end
