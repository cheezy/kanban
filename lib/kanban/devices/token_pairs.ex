defmodule Kanban.Devices.TokenPairs do
  @moduledoc """
  Inserts a device's access and refresh token pair, for
  `Kanban.Devices.issue_tokens/2` and refresh-token rotation
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §8).

  An access token lasts one hour. A refresh token expires 30 days after it
  was issued, and never later than 90 days after the device signed in (its
  `inserted_at`). The caller holds the device's row lock and owns the
  transaction, so a failed insert rolls back with it.
  """

  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Repo

  @access_ttl_seconds 3600
  @refresh_idle_days 30
  @refresh_absolute_days 90

  @doc """
  Inserts a new access and refresh token for `device` in token family
  `family_id`, issued at `now`, and returns them with their plain values:
  the only place those are ever shown.
  """
  @spec insert(Device.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Kanban.Devices.issued()} | {:error, Ecto.Changeset.t()}
  def insert(%Device{} = device, family_id, now) do
    access = token_attrs(:access, family_id, access_expiry(now), now)
    refresh = token_attrs(:refresh, family_id, refresh_expiry(device, now), now)

    with {:ok, access_token} <- insert_token(device, access),
         {:ok, refresh_token} <- insert_token(device, refresh) do
      {:ok, issued(device, access_token, refresh_token)}
    end
  end

  @doc """
  When a refresh token issued to `device` at `now` expires: 30 days from
  `now`, but never past 90 days after the device signed in.
  """
  @spec refresh_expiry(Device.t(), DateTime.t()) :: DateTime.t()
  def refresh_expiry(%Device{inserted_at: signed_in_at}, now) do
    idle = DateTime.add(now, @refresh_idle_days, :day)
    absolute = DateTime.add(signed_in_at, @refresh_absolute_days, :day)
    Enum.min([idle, absolute], DateTime)
  end

  defp token_attrs(kind, family_id, expires_at, now),
    do: %{kind: kind, family_id: family_id, expires_at: expires_at, inserted_at: now}

  defp insert_token(device, attrs) do
    device
    |> DeviceToken.new_changeset(attrs)
    |> Repo.insert()
  end

  defp issued(device, access, refresh) do
    %{
      device: device,
      access_token: access.token,
      access_token_expires_at: access.expires_at,
      refresh_token: refresh.token,
      refresh_token_expires_at: refresh.expires_at
    }
  end

  defp access_expiry(now), do: DateTime.add(now, @access_ttl_seconds, :second)
end
