defmodule KanbanWeb.ResourcesLive.Seo do
  @moduledoc """
  The meta descriptions the Resources pages pass to `KanbanWeb.SeoComponents`.

  The index has its own translated description. A how-to uses its own
  `description` — authored English data, never passed through gettext —
  shortened on a word boundary to fit a search result, and falls back to the
  index description when it has none. Both values reach the page only through
  seo_head's escaped attributes.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @max_length 160

  @doc "The description of the Resources index, in the current locale."
  @spec resources_description() :: String.t()
  def resources_description do
    gettext(
      "Step-by-step guides for Stride: set up boards, write tasks agents can finish, review their work, connect integrations and run an organization."
    )
  end

  @doc """
  The description of a how-to page: its own description, at most #{@max_length}
  characters, or `resources_description/0` when it has none.
  """
  @spec how_to_meta_description(map()) :: String.t()
  def how_to_meta_description(%{description: description}) when is_binary(description),
    do: description |> String.trim() |> describe()

  def how_to_meta_description(_how_to), do: resources_description()

  defp describe(""), do: resources_description()
  defp describe(text), do: shorten(text, String.length(text))

  defp shorten(text, length) when length <= @max_length, do: text

  defp shorten(text, _length) do
    text
    |> String.slice(0, @max_length - 1)
    |> String.replace(~r/\s+\S*$/u, "")
    |> drop_dangling_ending()
    |> Kernel.<>("…")
  end

  # A cut that ends on "and", "the" or a comma reads as broken in a search
  # result, so trailing punctuation and short connecting words are dropped
  # until the text ends on a word that carries meaning.
  @dangling_ending ~r/(?:[\s,;:]+|\s+(?:a|an|and|as|at|but|by|for|from|in|into|of|on|or|the|then|to|when|with))+$/iu

  defp drop_dangling_ending(text) do
    case String.replace(text, @dangling_ending, "") do
      "" -> text
      trimmed -> trimmed
    end
  end
end
