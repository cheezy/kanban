defmodule Kanban.Notifications.Recipients do
  @moduledoc """
  Decides who receives an event and through which channels.

  `resolve/4` drops `nil` entries and duplicates, drops users who are not
  current members of the event's board (when one is named), and applies each
  remaining user's preference for the event type — their saved row, else the
  default passed in. In-app and email are independent: a user is kept when
  either channel is on, and dropped only when both are off.

  Membership rows are read with `FOR SHARE` locks, so when this runs inside
  the notify transaction a concurrent board removal waits for it instead of
  committing between the check and the insert.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Preference
  alias Kanban.Repo

  @type delivery :: %{user_id: pos_integer(), in_app: boolean(), email: boolean()}

  @doc """
  Returns one delivery per recipient who should hear about the event, in
  recipient order.
  """
  @spec resolve(atom(), list(), pos_integer() | nil, Preference.t()) :: [delivery()]
  def resolve(event_type, recipients, board_id, %Preference{} = default) do
    ids = recipient_ids(recipients)
    members = board_members(board_id, ids)
    saved = saved_preferences(event_type, ids)

    ids
    |> Enum.filter(&member?(members, &1))
    |> Enum.map(&delivery(&1, Map.get(saved, &1, default)))
    |> Enum.filter(&(&1.in_app or &1.email))
  end

  defp recipient_ids(recipients) do
    recipients
    |> List.wrap()
    |> Enum.filter(&match?(%{id: id} when is_integer(id), &1))
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp delivery(user_id, preference) do
    %{user_id: user_id, in_app: preference.in_app, email: preference.email}
  end

  # nil means "no board named": the changeset decides whether a board-less
  # row is valid for the event type.
  defp member?(nil, _user_id), do: true
  defp member?(members, user_id), do: MapSet.member?(members, user_id)

  defp board_members(nil, _ids), do: nil

  defp board_members(board_id, ids) do
    BoardUser
    |> where([bu], bu.board_id == ^board_id and bu.user_id in ^ids)
    |> select([bu], bu.user_id)
    |> lock("FOR SHARE")
    |> Repo.all()
    |> MapSet.new()
  end

  defp saved_preferences(_event_type, []), do: %{}

  defp saved_preferences(event_type, ids) do
    Preference
    |> where([p], p.user_id in ^ids and p.event_type == ^event_type)
    |> select([p], {p.user_id, %{in_app: p.in_app, email: p.email}})
    |> Repo.all()
    |> Map.new()
  end
end
