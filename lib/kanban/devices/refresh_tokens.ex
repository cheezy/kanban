defmodule Kanban.Devices.RefreshTokens do
  @moduledoc """
  What a refresh token does (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.1, §8), behind `Kanban.Devices.rotate_refresh_token/3` (the
  `refresh_token` grant of `POST /oauth/token`),
  `Kanban.Devices.revoke_by_refresh_token/3` (`POST /oauth/revoke`).

  A rotation for a member overdue on their Organization's two-factor
  requirement is refused unless the device carries that Organization's
  single sign-on exemption, read again now (`Kanban.Devices.SsoExemption`).

  Both rotation and revocation lock the token's device row first and the
  token row second, the order `Kanban.Devices.Revocation` uses, so they
  never deadlock with each other or with another revocation. Holding the
  device lock serialises a rotation against a revocation of its device: a
  rotation that waited on a revocation reads the revoked row and is refused,
  and a revocation that waited on a rotation expires the pair it committed.
  """

  import Ecto.Query, warn: false

  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Revocation
  alias Kanban.Devices.SsoExemption
  alias Kanban.Devices.TokenPairs
  alias Kanban.Repo

  @doc "See `Kanban.Devices.rotate_refresh_token/3`."
  @spec rotate(term(), DateTime.t(), keyword()) ::
          {:ok, Devices.issued()} | {:error, :invalid_token | :reuse_detected}
  def rotate(token, now, opts) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = DateTime.truncate(now, :second)

    hash
    |> rotate_in_transaction(at, Keyword.get(opts, :client_id))
    |> unwrap_rotation(opts)
  end

  def rotate(_token, _now, _opts), do: {:error, :invalid_token}

  @doc "See `Kanban.Devices.revoke_by_refresh_token/3`."
  @spec revoke(term(), DateTime.t(), keyword()) :: {:ok, Device.t()} | {:error, :invalid_token}
  def revoke(token, now, opts) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = DateTime.truncate(now, :second)

    Repo.transact(fn ->
      hash
      |> device_id_for_hash()
      |> lock_device_with_user()
      |> lock_refresh_token(hash)
      |> revoke_for_token(at)
    end)
    |> announce_signed_out(opts)
  end

  def revoke(_token, _now, _opts), do: {:error, :invalid_token}

  # Locks the device row first and the token row second: the same order as
  # Kanban.Devices.Revocation, which locks the device and then updates its
  # tokens, so the two can never deadlock. Holding the device lock also
  # serializes the rotation against a revocation and against every other
  # rotation or issue on the device, so a revocation's expiry sweep sees
  # every token a rotation committed, and the device the checks read is the
  # locked row.
  defp rotate_in_transaction(hash, now, client_id) do
    Repo.transact(fn ->
      hash
      |> device_id_for_hash()
      |> lock_device_with_user()
      |> lock_refresh_token(hash)
      |> refuse_other_client(client_id)
      |> rotate_locked(now)
    end)
  end

  # An unused token presented by another client is treated as unknown, so it
  # stays usable by its own app; a used one goes on to reuse detection.
  defp refuse_other_client(%DeviceToken{used_at: nil, device: %{client_id: issued_to}}, client_id)
       when is_binary(client_id) and client_id != issued_to,
       do: nil

  defp refuse_other_client(token, _client_id), do: token

  defp device_id_for_hash(hash) do
    from(t in DeviceToken,
      where: t.token_hash == ^hash and t.kind == :refresh,
      select: t.device_id
    )
    |> Repo.one()
  end

  defp lock_device_with_user(nil), do: nil

  defp lock_device_with_user(device_id) do
    from(d in Device, where: d.id == ^device_id, lock: "FOR UPDATE")
    |> Repo.one()
    |> Repo.preload(:user)
  end

  defp lock_refresh_token(nil, _hash), do: nil

  defp lock_refresh_token(%Device{id: device_id} = device, hash) do
    query =
      from t in DeviceToken,
        where: t.token_hash == ^hash and t.kind == :refresh and t.device_id == ^device_id,
        lock: "FOR UPDATE"

    # A token row is only ever deleted with its device, which is now locked,
    # so the row found above is still there.
    token = Repo.one!(query)
    %{token | device: device}
  end

  defp rotate_locked(nil, _now), do: {:error, :invalid_token}
  defp rotate_locked(%{device: %{revoked_at: %DateTime{}}}, _now), do: {:error, :invalid_token}

  # Reuse is checked before expiry and before the user's state, so a stolen
  # token presented after it expired, or while its user is disabled, still
  # revokes the device and is audited. The revocation is returned as
  # {:ok, _} so that Repo.transact commits it.
  defp rotate_locked(%DeviceToken{used_at: %DateTime{}, device: device}, now) do
    with {:ok, revoked} <- Revocation.revoke_and_expire(device, nil, now),
         do: {:ok, {:reuse_detected, %{revoked | user: device.user}}}
  end

  defp rotate_locked(%{device: %{user: %{disabled_at: %DateTime{}}}}, _now),
    do: {:error, :invalid_token}

  defp rotate_locked(%DeviceToken{} = token, now) do
    cond do
      DateTime.compare(token.expires_at, now) != :gt -> {:error, :invalid_token}
      two_factor_refused?(token.device, now) -> {:error, :invalid_token}
      true -> replace(token, now)
    end
  end

  defp two_factor_refused?(%Device{user: user, sso_organization_id: sso_organization_id}, now),
    do: SsoExemption.two_factor_refused?(user, sso_organization_id, now)

  defp revoke_for_token(nil, _now), do: {:error, :invalid_token}
  defp revoke_for_token(%{device: %{revoked_at: %DateTime{}}}, _now), do: {:error, :invalid_token}

  defp revoke_for_token(%DeviceToken{device: device} = token, now) do
    if DateTime.compare(token.expires_at, now) == :gt,
      do: Revocation.revoke_and_expire(device, device.user_id, now),
      else: {:error, :invalid_token}
  end

  # The row is locked and unused, so exactly one row is marked; if the insert
  # that follows fails, the transaction rolls the mark back with it.
  defp replace(%DeviceToken{id: id, device: device, family_id: family_id}, now) do
    query = from(t in DeviceToken, where: t.id == ^id and is_nil(t.used_at))
    {1, _} = Repo.update_all(query, set: [used_at: now])
    TokenPairs.insert(device, family_id, now)
  end

  defp unwrap_rotation({:ok, {:reuse_detected, device}}, opts) do
    AuditLog.event(:device_refresh_reuse_detected,
      user_id: device.user_id,
      organization_id: Devices.organization_id(device.user),
      device_id: device.id,
      ip: Keyword.get(opts, :ip)
    )

    Revocation.announce({:ok, device},
      owner: device.user,
      user_id: device.user_id,
      reason: :reuse_detected,
      ip: Keyword.get(opts, :ip)
    )

    {:error, :reuse_detected}
  end

  defp unwrap_rotation(result, _opts), do: result

  # revoke_for_token/2 refuses an already revoked device, so every success
  # here is a new revocation.
  defp announce_signed_out({:ok, %Device{} = device} = result, opts) do
    Revocation.announce(result,
      owner: device.user,
      user_id: device.user_id,
      reason: :sign_out,
      ip: Keyword.get(opts, :ip)
    )
  end

  defp announce_signed_out(error, _opts), do: error
end
