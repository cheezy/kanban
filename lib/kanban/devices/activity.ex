defmodule Kanban.Devices.Activity do
  @moduledoc """
  Records when a device last used the person API, behind
  `Kanban.Devices.touch_last_seen/2`.

  The write is a single `UPDATE` that only moves `last_seen_at` forward, so
  two requests from the same device at once both succeed, neither takes an
  explicit lock, and an older request finishing last never moves it back.
  """

  import Ecto.Query, warn: false

  alias Kanban.Devices.Device
  alias Kanban.Repo

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
