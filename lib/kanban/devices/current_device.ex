defmodule Kanban.Devices.CurrentDevice do
  @moduledoc """
  What the app updates about the device it runs on
  (`PUT /api/me/devices/current`,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.10), behind
  `Kanban.Devices.update_current/4`.

  A push token belongs to one app install, so it is unique among devices.
  When the app registers a token another device still holds, such as the
  device the same phone was signed in as before, the token moves: the other
  device's token is cleared and this one gets it, in one transaction.

  The device and every device holding the new token are locked together,
  in id order, so two devices trading a token never deadlock, and a device
  revoked while the request was in flight is refused rather than updated.
  Before those row locks, a transaction-scoped advisory lock keyed on the
  token serialises every request registering it, so two devices registering
  a token that no device holds yet cannot both pass the row locks and leave
  the second to fail on the unique index: the second waits, then sees the
  first's row and moves the token from it.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Repo

  @doc """
  Updates the scope user's `device` with `attrs` at `now`. See
  `Kanban.Devices.update_current/4`.
  """
  @spec update(Scope.t(), Device.t(), map(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :not_found | :revoked | Ecto.Changeset.t()}
  def update(%Scope{user: %User{id: user_id}}, %Device{user_id: user_id, id: id}, attrs, now)
      when is_map(attrs) do
    token = requested_push_token(attrs, now)

    Repo.transact(fn ->
      id
      |> lock_rows(token)
      |> update_locked(id, attrs, now)
    end)
  end

  def update(%Scope{}, %Device{}, _attrs, _now), do: {:error, :not_found}

  # The token the request asks for, read before any row is locked so the
  # rows holding it can be locked with the device. nil when it sends none,
  # clears it, or sends one the changeset refuses: an invalid token, such as
  # one with a NUL byte Postgres cannot take, never reaches a query, and the
  # update then fails on the changeset before any row changes.
  defp requested_push_token(attrs, now) do
    changeset = Device.update_changeset(%Device{}, attrs, now)

    case {Ecto.Changeset.fetch_change(changeset, :push_token),
          Keyword.has_key?(changeset.errors, :push_token)} do
      {{:ok, token}, false} when is_binary(token) -> token
      _none_or_invalid -> nil
    end
  end

  defp lock_rows(id, nil) do
    from(d in Device, where: d.id == ^id, lock: "FOR UPDATE")
    |> Repo.all()
  end

  defp lock_rows(id, token) do
    lock_push_token(token)

    from(d in Device,
      where: d.id == ^id or d.push_token == ^token,
      order_by: d.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  # Held until the transaction ends. Keyed on a hash, so two different
  # tokens can share a key; that only makes them wait for each other.
  defp lock_push_token(token) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "user_devices.push_token:" <> token
    ])
  end

  defp update_locked(rows, id, attrs, now) do
    {own, others} = Enum.split_with(rows, &(&1.id == id))

    case own do
      [] -> {:error, :not_found}
      [%Device{revoked_at: %DateTime{}}] -> {:error, :revoked}
      [%Device{} = device] -> apply_update(device, others, attrs, now)
    end
  end

  defp apply_update(device, others, attrs, now) do
    changeset = Device.update_changeset(device, attrs, now)

    if changeset.valid? do
      release_push_token(changeset, others, now)
      Repo.update(changeset)
    else
      {:error, changeset}
    end
  end

  # Clears the token from the other devices that hold it, which are locked.
  defp release_push_token(changeset, others, now) do
    with {:ok, token} when is_binary(token) <- Ecto.Changeset.fetch_change(changeset, :push_token),
         ids when ids != [] <- for(%Device{push_token: ^token, id: id} <- others, do: id) do
      from(d in Device, where: d.id in ^ids)
      |> Repo.update_all(set: [push_token: nil, updated_at: now])
    end
  end
end
