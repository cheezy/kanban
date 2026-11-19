defmodule Kanban.Devices.PushTokens do
  @moduledoc """
  The devices a push can reach, for `Kanban.Push.PushWorker` and
  `Kanban.Notifications.notify/3` (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.8).

  A device can take a push when it is not revoked and has a push token.
  Revoking a device already clears its token; the `revoked_at` check is kept
  so a revocation always wins even if a token were left behind.

  `clear/1` drops a dead token (APNs `410 Unregistered`, FCM
  `UNREGISTERED`). It clears the token only while it is still the one that
  was sent to, so a token the app registered again in the meantime is kept.

  None of these functions logs or returns a token value except as part of the
  `Kanban.Devices.Device` structs `list_for_user/1` returns, whose
  `push_token` field is redacted when inspected.
  """

  import Ecto.Query, warn: false

  alias Kanban.Devices.Device
  alias Kanban.Repo

  @doc """
  Returns the ids, among `user_ids`, of the users with at least one device a
  push can reach, as a `MapSet`. One query for every user.
  """
  @spec user_ids_with_device([pos_integer()]) :: MapSet.t(pos_integer())
  def user_ids_with_device([]), do: MapSet.new()

  def user_ids_with_device(user_ids) when is_list(user_ids) do
    reachable()
    |> where([d], d.user_id in ^user_ids)
    |> select([d], d.user_id)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Lists the user's devices a push can reach, oldest first.
  """
  @spec list_for_user(pos_integer()) :: [Device.t()]
  def list_for_user(user_id) when is_integer(user_id) do
    reachable()
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], asc: d.id)
    |> Repo.all()
  end

  @doc """
  Reads `device` again and returns it when a push can still reach it, for
  the same user, else `nil`. `Kanban.Push.PushWorker` calls this just before
  each send, so a device revoked, or whose token moved to another device,
  while the job runs gets nothing.
  """
  @spec current(Device.t()) :: Device.t() | nil
  def current(%Device{id: id, user_id: user_id}) do
    reachable()
    |> where([d], d.id == ^id and d.user_id == ^user_id)
    |> Repo.one()
  end

  @doc """
  Clears `device`'s push token when it still holds the token it was loaded
  with. Returns `:ok` either way.
  """
  @spec clear(Device.t()) :: :ok
  def clear(%Device{id: id, push_token: token}) when is_binary(token) do
    Device
    |> where([d], d.id == ^id and d.push_token == ^token)
    |> Repo.update_all(
      set: [push_token: nil, updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    :ok
  end

  def clear(%Device{}), do: :ok

  defp reachable do
    from(d in Device,
      where: is_nil(d.revoked_at) and not is_nil(d.push_token) and d.push_token != ""
    )
  end
end
