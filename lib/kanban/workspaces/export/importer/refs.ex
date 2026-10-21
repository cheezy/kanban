defmodule Kanban.Workspaces.Export.Importer.Refs do
  @moduledoc """
  Names a refused archive row in `Kanban.Workspaces.Export.Importer`'s
  `{:invalid_row, entity, ref, errors}` error, which `mix
  kanban.import_workspace` prints.

  Text taken from the archive (a name, a task identifier) is cut to 60
  characters with an ellipsis (decided 2026-10-21), so a crafted archive with
  a 5,000-character label name does not fill the operator's terminal. A
  board, column or label is named by its name and its archive id, and an
  integer id is kept in full, so the operator can still find the row. Text
  that cannot be printed (a NUL byte or invalid UTF-8) is not echoed.
  """

  alias Kanban.ChangesetText

  @max_length 60

  @doc """
  The ref for `subject`: a row map is named by `name_ref/1`, text is
  shortened, an integer is kept, and anything else is "unnamed row".

  ## Examples

      iex> ref("W12")
      "W12"

      iex> ref(%{"id" => 3, "name" => "Alpha board"})
      ~s("Alpha board", id 3)

  """
  @spec ref(term()) :: String.t()
  def ref(%{} = row) when not is_struct(row), do: name_ref(row)
  def ref(text) when is_binary(text), do: shorten(text)
  def ref(id) when is_integer(id), do: Integer.to_string(id)
  def ref(_subject), do: "unnamed row"

  @doc """
  The ref for a board, column or label row: its quoted name, shortened, and
  its archive id.

  ## Examples

      iex> name_ref(%{"id" => 3, "name" => "Alpha board"})
      ~s("Alpha board", id 3)

      iex> name_ref(%{"id" => 3})
      "id 3"

  """
  @spec name_ref(map()) :: String.t()
  def name_ref(%{} = row) do
    case Enum.reject([quoted_name(row["name"]), id_part(row["id"])], &is_nil/1) do
      [] -> "unnamed row"
      parts -> Enum.join(parts, ", ")
    end
  end

  @doc """
  `text` cut to #{@max_length} characters, with an ellipsis when it was cut.
  Text with a NUL byte or invalid UTF-8 becomes "(text that cannot be shown)".

  ## Examples

      iex> shorten("Alpha board")
      "Alpha board"

  """
  @spec shorten(String.t()) :: String.t()
  def shorten(text) when is_binary(text) do
    cond do
      not ChangesetText.storable?(text) -> "(text that cannot be shown)"
      String.length(text) > @max_length -> String.slice(text, 0, @max_length) <> "…"
      true -> text
    end
  end

  defp quoted_name(name) when is_binary(name), do: ~s("#{shorten(name)}")
  defp quoted_name(_name), do: nil

  defp id_part(id) when is_integer(id), do: "id #{id}"
  defp id_part(id) when is_binary(id), do: "id #{shorten(id)}"
  defp id_part(_id), do: nil
end
