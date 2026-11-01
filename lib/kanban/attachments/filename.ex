defmodule Kanban.Attachments.Filename do
  @moduledoc """
  Turns a client-supplied file name into one that is safe to store and show.

  `sanitize/1` applies these steps in order:

    1. Refuses anything that is not a valid UTF-8 string (`:invalid`).
    2. Removes control characters (`\\p{Cc}`, such as NUL, tab and newline)
       and format characters (`\\p{Cf}`, which include the bidi overrides
       U+202A–U+202E and U+2066–U+2069). A bidi override could otherwise make
       `photo\\u202Egnp.exe` display as `photoexe.png`. The zero-width
       non-joiner and joiner (U+200C, U+200D) are kept, because they reorder
       nothing and emoji sequences (`👨‍👩‍👧`) and scripts such as Persian need
       them; a name made only of them is refused by the changeset as blank.
    3. Keeps only the part after the last `/` or `\\`, so a name can never
       carry a directory, absolute or relative (`../../etc/passwd` becomes
       `passwd`, `C:\\Users\\x\\evil.png` becomes `evil.png`).
    4. Trims surrounding whitespace.
    5. Refuses a name left empty, or equal to `.` or `..` (`:empty`).
    6. Caps the name at 255 codepoints, keeping its extension, so the
       stored name always fits the column and keeps its type hint.

  This module checks only the name. File bytes are checked by
  `Kanban.Attachments.ContentType`, and are never required to be UTF-8.
  """

  @max_codepoints 255
  # Every control and format character except the zero-width non-joiner and
  # joiner (U+200C, U+200D), which neither reorder nor hide text: emoji
  # sequences and scripts such as Persian need them.
  @unsafe ~r/(?![\x{200C}\x{200D}])[\p{Cc}\p{Cf}]/u
  @separators ~r{[/\\]}

  @type reason :: :invalid | :empty

  @doc "The most codepoints a sanitised name may hold."
  @spec max_codepoints() :: pos_integer()
  def max_codepoints, do: @max_codepoints

  @doc """
  Sanitises `name`. Returns `{:ok, name}`, or `{:error, :invalid}` for a value
  that is not a valid UTF-8 string, or `{:error, :empty}` for a name that is
  empty, `.` or `..` once sanitised.
  """
  @spec sanitize(term()) :: {:ok, String.t()} | {:error, reason()}
  def sanitize(name) when is_binary(name) do
    if String.valid?(name), do: sanitize_valid(name), else: {:error, :invalid}
  end

  def sanitize(_name), do: {:error, :invalid}

  defp sanitize_valid(name) do
    name
    |> String.replace(@unsafe, "")
    |> String.split(@separators)
    |> List.last()
    |> String.trim()
    |> finish()
  end

  defp finish(name) when name in ["", ".", ".."], do: {:error, :empty}
  defp finish(name), do: {:ok, cap(name)}

  defp cap(name) do
    codepoints = String.codepoints(name)

    if length(codepoints) <= @max_codepoints do
      name
    else
      extension = name |> Path.extname() |> String.codepoints()
      cap_keeping_extension(codepoints, extension)
    end
  end

  defp cap_keeping_extension(codepoints, extension)
       when extension != [] and length(extension) < @max_codepoints do
    base = Enum.take(codepoints, @max_codepoints - length(extension))
    Enum.join(base ++ extension)
  end

  defp cap_keeping_extension(codepoints, _extension) do
    codepoints |> Enum.take(@max_codepoints) |> Enum.join()
  end
end
