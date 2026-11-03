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

  `printable/1` is applied to every line `mix kanban.import_workspace` prints
  (decided 2026-11-03), because the report carries archive text that is not a
  ref: the workspace name, user emails, task identifiers and board names. It
  shows each control character as a visible escape, so a crafted archive
  cannot send terminal control sequences to the operator's terminal. The
  stored names are never changed.
  """

  alias Kanban.ChangesetText

  @max_length 60

  # The marks (LRM, RLM, ALM) and the embedding, override and isolate
  # controls, which a terminal that does bidi can use to reorder a line.
  @bidi_controls [0x061C, 0x200E, 0x200F] ++
                   Enum.to_list(0x202A..0x202E) ++ Enum.to_list(0x2066..0x2069)

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

  @doc ~S"""
  `text` with every character that can control a terminal shown as a
  visible escape: ESC as `\e`, newline, carriage return and tab as `\n`,
  `\r` and `\t`, any other C0 control or DEL as `\xNN`, and the C1
  controls and the bidirectional embedding, override, isolate and mark
  characters as `\u{NNNN}`. A byte that is not valid UTF-8 is shown as
  `\xNN`. Every other character, a backslash included, is kept.

  ## Examples

      iex> printable("Alpha board")
      "Alpha board"

      iex> printable("Alpha\e[2J board")
      "Alpha\\e[2J board"

  """
  @spec printable(String.t()) :: String.t()
  def printable(text) when is_binary(text), do: text |> escape([]) |> IO.iodata_to_binary()

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<cp::utf8, rest::binary>>, acc), do: escape(rest, [escape_char(cp) | acc])
  defp escape(<<byte, rest::binary>>, acc), do: escape(rest, [hex(byte) | acc])

  defp escape_char(?\e), do: "\\e"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(cp) when cp < 0x20 or cp == 0x7F, do: hex(cp)
  defp escape_char(cp) when cp in 0x80..0x9F or cp in @bidi_controls, do: unicode(cp)
  defp escape_char(cp), do: <<cp::utf8>>

  defp hex(byte), do: "\\x" <> (byte |> Integer.to_string(16) |> String.pad_leading(2, "0"))

  defp unicode(cp),
    do: "\\u{" <> (cp |> Integer.to_string(16) |> String.pad_leading(4, "0")) <> "}"

  defp quoted_name(name) when is_binary(name), do: ~s("#{shorten(name)}")
  defp quoted_name(_name), do: nil

  defp id_part(id) when is_integer(id), do: "id #{id}"
  defp id_part(id) when is_binary(id), do: "id #{shorten(id)}"
  defp id_part(_id), do: nil
end
