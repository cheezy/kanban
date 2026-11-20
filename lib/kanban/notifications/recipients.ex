defmodule Kanban.Notifications.Recipients do
  @moduledoc """
  Decides who receives an event and through which channels.

  `resolve/4` drops `nil` entries and duplicates, drops users who are not
  current members of the event's board (when one is named) or, for an event
  with no board, ids with no user row, and applies each
  remaining user's preference for the event type — their saved row, else the
  default passed in. In-app, email and push are independent: a user is kept
  when any channel is on, and dropped only when all three are off. A user
  kept for push alone is dropped later by `Kanban.Notifications.notify/3`
  when no push can reach them (`Kanban.Push.PushWorker.recipient_ids/2`).

  Membership rows are read with `FOR SHARE` locks, so when this runs inside
  the notify transaction a concurrent board removal waits for it instead of
  committing between the check and the insert. With no board, the users'
  own rows are read with `FOR KEY SHARE`, so a user deleted meanwhile waits
  for the insert instead of failing it; an ordinary update to the user is
  not held up.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Preference
  alias Kanban.Repo

  @type delivery :: %{
          user_id: pos_integer(),
          in_app: boolean(),
          email: boolean(),
          push: boolean()
        }

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
    |> Enum.filter(&any_channel?/1)
  end

  defp any_channel?(%{in_app: in_app, email: email, push: push}), do: in_app or email or push

  defp recipient_ids(recipients) do
    recipients
    |> List.wrap()
    |> Enum.filter(&match?(%{id: id} when is_integer(id), &1))
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp delivery(user_id, preference) do
    %{
      user_id: user_id,
      in_app: preference.in_app,
      email: preference.email,
      push: preference.push
    }
  end

  # With no board named, the ids that have a user row: an unknown id is
  # dropped, as the board path drops a non-member, instead of failing every
  # recipient's row on its foreign key. The changeset still decides whether a
  # board-less row is valid for the event type.
  defp member?(members, user_id), do: MapSet.member?(members, user_id)

  defp board_members(_board_id, []), do: MapSet.new()

  defp board_members(nil, ids) do
    User
    |> where([u], u.id in ^ids)
    |> select([u], u.id)
    |> lock("FOR KEY SHARE")
    |> Repo.all()
    |> MapSet.new()
  end

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
    |> select([p], {p.user_id, %{in_app: p.in_app, email: p.email, push: p.push}})
    |> Repo.all()
    |> Map.new()
  end
end
