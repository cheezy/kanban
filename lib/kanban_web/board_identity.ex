defmodule KanbanWeb.BoardIdentity do
  @moduledoc """
  Pure helpers for a board's visual identity — the 3-letter monogram, the
  accent CSS variable, and the blank-string presence check used around
  board descriptions.

  Extracted from the byte-identical private copies that previously lived in
  `KanbanWeb.BoardHeader`, `KanbanWeb.BoardPulseCard`, and (for
  `present?/1`) `KanbanWeb.GoalCard` (W1089). Sits beside
  `KanbanWeb.BoardAccent` (which assigns accents to boards) and follows the
  `KanbanWeb.TaskTokens` pure-token-module pattern; rendering stays in the
  components.
  """

  @doc """
  Builds the 3-letter uppercase monogram for a board name, padding short
  names with question marks. Non-binary input renders `"???"`.
  """
  def board_prefix(name) when is_binary(name) do
    letters =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "")

    letters
    |> String.slice(0, 3)
    |> String.pad_trailing(3, "?")
  end

  def board_prefix(_), do: "???"

  @doc """
  Maps a board accent atom to its CSS custom property, falling back to the
  muted ink token for unknown accents.
  """
  def accent_color(:orange), do: "var(--stride-orange)"
  def accent_color(:ready), do: "var(--st-ready)"
  def accent_color(:doing), do: "var(--st-doing)"
  def accent_color(:violet), do: "var(--stride-violet)"
  def accent_color(:backlog), do: "var(--st-backlog)"
  def accent_color(:blocked), do: "var(--st-blocked)"
  def accent_color(_other), do: "var(--ink-3)"

  @doc """
  True only for a binary with non-whitespace content.
  """
  def present?(nil), do: false
  def present?(""), do: false
  def present?(s) when is_binary(s), do: String.trim(s) != ""
  def present?(_), do: false
end
