defmodule KanbanWeb.AgentsLive.Filters do
  @moduledoc """
  Client-payload parsing and in-memory filtering for `KanbanWeb.AgentsLive`,
  extracted from the LiveView to keep it under the module-size guideline.

  Holds the allow-list parsers for the board/time-range selector and the
  activity-feed kind tabs, the kind + selected-agent event filter shared by the
  event handlers and the data load (`KanbanWeb.AgentsLive.DataLoader`), and the
  two small toggles behind agent selection and detail-section collapse. Moved
  unchanged; every function is pure (no socket, no DB access).
  """

  alias Kanban.Agents

  # The board select submits "" for "All boards" and a numeric id otherwise; an
  # unparseable value falls back to nil (all boards) rather than crashing.
  @doc false
  def parse_board_id(id) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {board_id, ""} -> board_id
      _ -> nil
    end
  end

  def parse_board_id(_id), do: nil

  # Explicit allow-list mapping (no String.to_atom on user input); anything
  # unrecognized falls back to :all_time, the unfiltered default.
  @doc false
  def parse_time_range("today"), do: :today
  def parse_time_range("last_7_days"), do: :last_7_days
  def parse_time_range("last_30_days"), do: :last_30_days
  def parse_time_range("last_90_days"), do: :last_90_days
  def parse_time_range(_range), do: :all_time

  @doc false
  def parse_filter("all"), do: :all
  def parse_filter("claims"), do: :claims
  def parse_filter("reviewed"), do: :reviewed
  def parse_filter("completions"), do: :completions
  def parse_filter(_), do: :all

  defp filter_events(events, :all), do: events
  defp filter_events(events, :claims), do: Enum.filter(events, &(&1.kind == :claim))
  defp filter_events(events, :reviewed), do: Enum.filter(events, &(&1.kind == :review))
  defp filter_events(events, :completions), do: Enum.filter(events, &(&1.kind == :complete))

  # Composes the kind filter with the optional agent filter. The kind filter
  # always runs first; when an agent identity {name, owner_key} is selected,
  # only events whose actor name AND owner key match survive — so selecting one
  # of two same-named agents shows only that human's events (W1244). A nil
  # selection leaves the kind-filtered list untouched.
  @doc false
  def apply_filters(events, kind_filter, nil), do: filter_events(events, kind_filter)

  def apply_filters(events, kind_filter, {name, owner_key}) do
    events
    |> filter_events(kind_filter)
    |> Enum.filter(&(&1.actor == name and Agents.owner_key_for_owner(&1.owner) == owner_key))
  end

  # Toggling the currently-selected agent identity clears the selection; any
  # other identity replaces it. Identities are {name, owner_key} tuples, so
  # equality is by value.
  @doc false
  def toggle_agent(selected_identity, selected_identity), do: nil
  def toggle_agent(_current, identity), do: identity

  # Flip a member's presence in a MapSet: drop it when present, add it when
  # absent. Backs the per-section collapse state for the detail panel.
  @doc false
  def toggle_member(set, member) do
    if MapSet.member?(set, member),
      do: MapSet.delete(set, member),
      else: MapSet.put(set, member)
  end
end
