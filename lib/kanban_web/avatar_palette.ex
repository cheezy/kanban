defmodule KanbanWeb.AvatarPalette do
  @moduledoc """
  Deterministic palette resolver for `KanbanWeb.Avatar` callers.

  Anywhere a person or agent renders as an avatar — board member stack,
  goal-view member stack, child-row table, task-detail metadata grid —
  the same identity must map to the same colour. This module is the
  single source of truth; `Kanban.Boards.members_by_board/1` and
  `KanbanWeb.BoardLive.Show` both route through `for_human/1` and
  `for_agent/1` so the goal view inherits the exact same palette the
  board uses.

  The human algorithm is `rem(user_id, 4)` so user `42` is always pink,
  `43` is always blue, and so on. Agent names match a known vendor
  prefix (Claude / Cursor / Aider / Codex) and fall back to `agent-claude`.
  """

  @human_palettes ~w(human-blue human-amber human-green human-pink)
  @agent_palettes ~w(agent-claude agent-cursor agent-aider agent-codex)

  @doc """
  Returns one of the four `human-*` palette strings for a user id.
  Uses `rem/2` so the palette is stable across requests and matches
  the algorithm the board member stack has used since W437.
  """
  def for_human(id) when is_integer(id) do
    Enum.at(@human_palettes, rem(id, length(@human_palettes)))
  end

  def for_human(_), do: "human-blue"

  @doc """
  Returns one of the four `agent-*` palette strings for an agent name.
  Matches the first lower-cased word against the known vendor prefixes;
  anything else falls back to `agent-claude` so unknown agents render
  consistently.
  """
  def for_agent(name) when is_binary(name) do
    case name |> String.downcase() |> String.split() |> List.first() do
      "claude" -> "agent-claude"
      "cursor" -> "agent-cursor"
      "aider" -> "agent-aider"
      "codex" -> "agent-codex"
      _ -> "agent-claude"
    end
  end

  def for_agent(_), do: "agent-claude"

  @doc "Exposed for tests / introspection."
  def human_palettes, do: @human_palettes

  @doc "Exposed for tests / introspection."
  def agent_palettes, do: @agent_palettes
end
