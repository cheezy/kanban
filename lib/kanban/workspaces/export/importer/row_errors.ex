defmodule Kanban.Workspaces.Export.Importer.RowErrors do
  @moduledoc """
  The errors of an archive row's changeset, with their `%{...}` placeholders
  filled in: as a map for the `{:invalid_row, ...}` error that refuses an
  import (`errors/1`), or as one line of text for the import report naming a
  row that was skipped (`text/1`).
  """

  @doc """
  The changeset's errors by field, each message interpolated.
  """
  @spec errors(Ecto.Changeset.t()) :: %{optional(atom()) => [String.t()]}
  def errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> interpolation(value) end)
      end)
    end)
  end

  @doc """
  The changeset's errors as one line, fields in alphabetical order, such as
  `content_type does not match the file contents; filename can't be blank`.
  """
  @spec text(Ecto.Changeset.t()) :: String.t()
  def text(%Ecto.Changeset{} = changeset) do
    changeset
    |> errors()
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp interpolation(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp interpolation(value), do: inspect(value)
end
