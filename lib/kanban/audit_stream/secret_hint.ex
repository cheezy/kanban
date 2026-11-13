defmodule Kanban.AuditStream.SecretHint do
  @moduledoc """
  The hint `Kanban.AuditStream.Destination` shows in place of a secret: its
  last 4 characters, for a secret of at least 16.

  A secret shorter than 16 codepoints gets no hint, so a hint never shows a
  large share of a short secret. The hint is the last whole characters that
  fit in 4 codepoints (the `varchar(4)` columns), never splitting a
  character made of several codepoints, so it can be shorter than 4, and is
  nil when the last character alone is wider than 4.
  """

  @hint_length 4
  @hint_min_length 16

  @doc "The hint for `value`, or nil when it is too short or nil."
  @spec hint(String.t() | nil) :: String.t() | nil
  def hint(value) when is_binary(value) do
    if length(String.codepoints(value)) >= @hint_min_length do
      value |> String.graphemes() |> Enum.reverse() |> take_hint([], 0)
    end
  end

  def hint(nil), do: nil

  defp take_hint([grapheme | rest], acc, size) do
    grapheme_size = length(String.codepoints(grapheme))

    if size + grapheme_size <= @hint_length,
      do: take_hint(rest, [grapheme | acc], size + grapheme_size),
      else: join_hint(acc)
  end

  defp take_hint([], acc, _size), do: join_hint(acc)

  defp join_hint([]), do: nil
  defp join_hint(graphemes), do: Enum.join(graphemes)
end
