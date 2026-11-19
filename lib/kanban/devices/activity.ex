defmodule Kanban.Devices.Activity do
  @moduledoc """
  Records when a device last used the person API, behind
  `Kanban.Devices.touch_last_seen/2`, and says whether a device may still use
  it (`signed_in?/1`).

  The write is a single `UPDATE` that only moves `last_seen_at` forward, so
  two requests from the same device at once both succeed, neither takes an
  explicit lock, and an older request finishing last never moves it back.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Repo

  @doc """
  Whether `device` may still use the person API now: it exists, is not
  revoked, and its user is not disabled. The same conditions
  `Kanban.Devices.fetch_by_access_token/2` puts on the device, read again, so
  `KanbanWeb.Plugs.AuthenticateDeviceToken` can refuse a read whose device was
  revoked while the request was in flight.
  """
  @spec signed_in?(Device.t()) :: boolean()
  def signed_in?(%Device{id: id}) do
    from(d in Device,
      join: u in User,
      on: u.id == d.user_id,
      where: d.id == ^id and is_nil(d.revoked_at) and is_nil(u.disabled_at)
    )
    |> Repo.exists?()
  end

  @doc """
  Sets the device's `last_seen_at` to `now`, truncated to the second, unless
  it is already at or after it. Returns the device with that value.
  """
  @spec touch_last_seen(Device.t(), DateTime.t()) :: Device.t()
  def touch_last_seen(%Device{id: id} = device, now) do
    at = DateTime.truncate(now, :second)

    # GREATEST ignores a NULL, so a first touch sets it and a later one never
    # moves it back; RETURNING reads the value the row now holds.
    {_count, seen} =
      from(d in Device,
        where: d.id == ^id,
        select: d.last_seen_at,
        update: [
          set: [
            last_seen_at: fragment("GREATEST(?, ?)", d.last_seen_at, type(^at, :utc_datetime))
          ]
        ]
      )
      |> Repo.update_all([])

    %{device | last_seen_at: last_seen(seen, at)}
  end

  # A device deleted since it was read updates no row; report `at` rather
  # than crash, as the request is about to be refused or ignored anyway.
  defp last_seen([%DateTime{} = seen], _at), do: seen
  defp last_seen(_none, at), do: at
end
