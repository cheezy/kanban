defmodule Kanban.Devices do
  @moduledoc """
  Devices a person has signed in to Stride on, and their tokens
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  This is the token core the OAuth endpoints (`POST /oauth/token`,
  `POST /oauth/revoke`), the device plug and the device routes under
  `/api/me/devices` build on. Redeeming an authorization code lives in
  `Kanban.Devices.CodeExchange`, behind `exchange_authorization_code/4`;
  revoking a device in `Kanban.Devices.Revocation`, behind `revoke_device/4`;
  and the app updating its own device in `Kanban.Devices.CurrentDevice`,
  behind `update_current/4`.

    * **Access tokens** last one hour.
    * **Refresh tokens** rotate: each use returns a new pair and uses up the
      old refresh token. A refresh token expires 30 days after it was issued,
      and never later than 90 days after the device signed in (its
      `inserted_at`), so a device that keeps refreshing still signs in again
      every 90 days.
    * **Reusing a used refresh token** is the sign of a stolen token, so it
      revokes the device and expires every token it holds, the whole token
      family included, and the revocation commits even though the call fails.
    * **Authorization codes** live 60 seconds and are consumed once.
    * **Refresh is refused** for a disabled user, a revoked device, and a
      user whose Organization requires two-factor once their grace period
      is over (`{:overdue, _}`), the same line the web gate draws. A member
      still in grace can refresh. A device has no sign-in session, so the
      web gate's single sign-on exemption never applies to it.

  The security events are audited after their transaction commits, whoever
  the caller: `:device_signed_in` when a code exchange creates a device,
  `:device_refresh_reuse_detected` when reuse revokes one, and
  `:device_revoked`, with a reason, whenever a device is revoked. None
  carries a token, a code or the approval key. A revocation also emits
  `[:kanban, :device, :revoked]` and broadcasts on `"device:<id>"`
  (`Kanban.Devices.Revocation`).

  Tokens and codes are random, shown once and stored only as SHA-256 hashes
  (`Kanban.Devices.DeviceToken`). A plain value is looked up by hashing it and
  matching the hash in a unique index, as agent API tokens are, so no stored
  secret is ever compared in application code.

  A token is valid while the current second is before its `expires_at`: at
  exactly `expires_at` it is refused. Every function that reads the clock
  takes a trailing `now`, defaulting to the current time and truncated to the
  second, so tests can step through each boundary.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Devices.Activity
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.CodeExchange
  alias Kanban.Devices.CurrentDevice
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.Revocation
  alias Kanban.Devices.TokenPairs
  alias Kanban.Organizations
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Repo

  @typedoc "A newly issued token pair: the plain values are shown only here."
  @type issued :: %{
          device: Device.t(),
          access_token: String.t(),
          access_token_expires_at: DateTime.t(),
          refresh_token: String.t(),
          refresh_token_expires_at: DateTime.t()
        }

  @doc """
  Creates a device for the scope's user, signed in at `now`.
  """
  @spec create_device(Scope.t(), map(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def create_device(%Scope{user: %User{id: user_id}}, attrs, now \\ DateTime.utc_now()) do
    signed_in_at = truncate(now)

    %Device{user_id: user_id}
    |> Device.create_changeset(attrs, signed_in_at)
    |> Repo.insert()
  end

  @doc """
  Issues a new access and refresh token for `device`, starting a new token
  family. Refused for a revoked device, and with `{:error, :expired}` once the
  device is 90 days past sign-in, when a refresh token would be born expired:
  the person must sign in again as a new device.
  """
  @spec issue_tokens(Device.t(), DateTime.t()) :: {:ok, issued()} | {:error, :revoked | :expired}
  def issue_tokens(%Device{} = device, now \\ DateTime.utc_now()) do
    issued_at = truncate(now)

    Repo.transact(fn ->
      device.id
      |> share_lock_device()
      |> issue_for_locked(issued_at)
    end)
  end

  @doc """
  Finds the device an access token belongs to, with its user preloaded.

  Refused, with the same error whatever the cause, when the token is unknown,
  is not an access token, has expired, or belongs to a revoked device or a
  disabled user.
  """
  @spec fetch_by_access_token(term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :invalid_token}
  def fetch_by_access_token(token, now \\ DateTime.utc_now())

  def fetch_by_access_token(token, now) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = truncate(now)

    query =
      from t in DeviceToken,
        join: d in assoc(t, :device),
        join: u in assoc(d, :user),
        where: t.token_hash == ^hash and t.kind == :access and t.expires_at > ^at,
        where: is_nil(d.revoked_at) and is_nil(u.disabled_at),
        select: {d, u}

    case Repo.one(query) do
      {device, user} -> {:ok, %{device | user: user}}
      nil -> {:error, :invalid_token}
    end
  end

  def fetch_by_access_token(_token, _now), do: {:error, :invalid_token}

  @doc """
  Records that the device used the person API at `now`. Safe under
  concurrent requests and never moves `last_seen_at` backwards
  (`Kanban.Devices.Activity`).
  """
  @spec touch_last_seen(Device.t(), DateTime.t()) :: Device.t()
  def touch_last_seen(%Device{} = device, now \\ DateTime.utc_now()),
    do: Activity.touch_last_seen(device, now)

  @doc """
  Trades a refresh token for a new access and refresh token in the same
  family, using up the old refresh token.

  The device and then the old token are locked for the whole rotation, so of
  two rotations of one token exactly one wins, a rotation never races a
  revocation of its device, and the old token is marked used and the new
  pair inserted in one transaction: a failure leaves the old token usable
  and never two live refresh tokens.

  Presenting a refresh token that was already used revokes its device and
  expires all of its tokens, writes `:device_refresh_reuse_detected`, and
  returns `{:error, :reuse_detected}`. The loser of two concurrent rotations
  is such a reuse. Every other refusal, an unknown or expired token, a
  revoked device, a disabled user or a user overdue on their Organization's
  two-factor requirement, is `{:error, :invalid_token}` and leaves the token
  unused.

  `opts` takes `:ip`, the caller's address, recorded on the audit row, and
  `:client_id`, the client asking. When it is given, an unused token of a
  device signed in through another client is refused as `:invalid_token`
  and left unused: a refresh token works only for the app it was issued to.
  A used one is still reuse, whichever client presents it.
  """
  @spec rotate_refresh_token(term(), DateTime.t(), keyword()) ::
          {:ok, issued()} | {:error, :invalid_token | :reuse_detected}
  def rotate_refresh_token(token, now \\ DateTime.utc_now(), opts \\ [])

  def rotate_refresh_token(token, now, opts) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = truncate(now)

    hash
    |> rotate_in_transaction(at, Keyword.get(opts, :client_id))
    |> unwrap_rotation(opts)
  end

  def rotate_refresh_token(_token, _now, _opts), do: {:error, :invalid_token}

  @doc """
  Redeems an authorization code for a new device and its first token pair:
  the `authorization_code` grant of `POST /oauth/token`. See
  `Kanban.Devices.CodeExchange.exchange/4`.
  """
  @spec exchange_authorization_code(map(), map(), DateTime.t(), keyword()) ::
          {:ok, issued()} | {:error, :invalid_grant | Ecto.Changeset.t()}
  def exchange_authorization_code(grant, details, now \\ DateTime.utc_now(), opts \\ []),
    do: CodeExchange.exchange(grant, details, now, opts)

  @doc """
  Revokes the device a refresh token belongs to, as the device's own user,
  and expires its tokens: `POST /oauth/revoke` (RFC 7009), the app signing
  itself out.

  The token must be a refresh token that has not expired, used or not: an
  old token still names its device, as it does to rotation. Refused with
  `{:error, :invalid_token}` when the token is unknown, is not a refresh
  token, has expired, or its device is already revoked. The device and then
  the token are locked, the order rotation uses, so the two never deadlock.

  The revocation is announced with reason `:sign_out`
  (`Kanban.Devices.Revocation.announce/2`). `opts` takes `:ip`, recorded on
  the audit row.
  """
  @spec revoke_by_refresh_token(term(), DateTime.t(), keyword()) ::
          {:ok, Device.t()} | {:error, :invalid_token}
  def revoke_by_refresh_token(token, now \\ DateTime.utc_now(), opts \\ [])

  def revoke_by_refresh_token(token, now, opts) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = truncate(now)

    Repo.transact(fn ->
      hash
      |> refresh_token_device_id()
      |> lock_device_with_user()
      |> lock_refresh_token(hash)
      |> revoke_for_token(at)
    end)
    |> announce_signed_out(opts)
  end

  def revoke_by_refresh_token(_token, _now, _opts), do: {:error, :invalid_token}

  @doc """
  The id of the device a refresh token belongs to, or `nil`. It reads no
  token's state, so it says nothing about whether the token is usable: it
  is only the key `POST /oauth/token` and `POST /oauth/revoke` rate-limit a
  device by.
  """
  @spec device_id_for_refresh_token(term()) :: pos_integer() | nil
  def device_id_for_refresh_token(token) when is_binary(token),
    do: token |> DeviceToken.hash_token() |> refresh_token_device_id()

  def device_id_for_refresh_token(_token), do: nil

  @doc """
  Revokes one of the scope user's devices at `now` and expires its tokens,
  recording the scope user in `revoked_by_id`.

  Once it commits, the revocation writes `:device_revoked`, emits
  `[:kanban, :device, :revoked]` and broadcasts on `"device:<id>"`
  (`Kanban.Devices.Revocation`). `opts` takes `:reason`, `:user` (the
  default) when the person revokes a device, or `:sign_out` when the app
  signs itself out, `:ip`, recorded on the audit row, and `:by_device`, the
  device the request came from: when that device has been revoked, as it
  can be while its request is in flight, nothing is revoked and the result
  is `{:error, :revoked}`.

  A device that is already revoked is returned unchanged, and nothing is
  written or broadcast again. A device of another user is
  `{:error, :not_found}`. `now` must be a `DateTime`, so options are never
  mistaken for it.
  """
  @spec revoke_device(Scope.t(), Device.t(), DateTime.t(), keyword()) ::
          {:ok, Device.t()} | {:error, :not_found | :revoked}
  def revoke_device(scope, device, now \\ DateTime.utc_now(), opts \\ [])

  def revoke_device(%Scope{} = scope, %Device{} = device, %DateTime{} = now, opts)
      when is_list(opts),
      do: Revocation.revoke_own(scope, device, truncate(now), opts)

  @doc """
  Gets one of the scope user's devices by id, revoked or not. Another
  user's device, or an id that names no device, is `{:error, :not_found}`.
  """
  @spec fetch_device(Scope.t(), pos_integer()) :: {:ok, Device.t()} | {:error, :not_found}
  def fetch_device(%Scope{user: %User{id: user_id}}, id) when is_integer(id) do
    case Repo.get_by(Device, id: id, user_id: user_id) do
      %Device{} = device -> {:ok, device}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Updates the device the app runs on, one of the scope user's, with `attrs`
  at `now`: its push token and push environment, locale, time zone and app
  version (`Kanban.Devices.Device.update_changeset/3`). A push token another
  device holds moves to this one.

  A device revoked while the request was in flight is `{:error, :revoked}`;
  another user's device is `{:error, :not_found}`; invalid attributes are
  `{:error, changeset}`. See `Kanban.Devices.CurrentDevice`.
  """
  @spec update_current(Scope.t(), Device.t(), map(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :not_found | :revoked | Ecto.Changeset.t()}
  def update_current(%Scope{} = scope, %Device{} = device, attrs, now \\ DateTime.utc_now()),
    do: CurrentDevice.update(scope, device, attrs, truncate(now))

  @doc """
  Lists the scope user's devices that are not revoked, newest first, for a
  request from `device`. When `device` is not among them, because it was
  revoked while the request was in flight, the result is
  `{:error, :revoked}`; both come from one read.
  """
  @spec list_devices_for(Scope.t(), Device.t()) :: {:ok, [Device.t()]} | {:error, :revoked}
  def list_devices_for(%Scope{} = scope, %Device{id: id}) do
    devices = list_devices(scope)
    if Enum.any?(devices, &(&1.id == id)), do: {:ok, devices}, else: {:error, :revoked}
  end

  @doc """
  Lists the scope user's devices that are not revoked, newest first.
  """
  @spec list_devices(Scope.t()) :: [Device.t()]
  def list_devices(%Scope{user: %User{id: user_id}}) do
    from(d in Device,
      where: d.user_id == ^user_id and is_nil(d.revoked_at),
      order_by: [desc: d.inserted_at, desc: d.id]
    )
    |> Repo.all()
  end

  @doc """
  Issues a one-time authorization code for the scope's user at `now`. The
  plain code is in the returned struct's `code` field and nowhere else.
  """
  @spec create_authorization_code(Scope.t(), map(), DateTime.t()) ::
          {:ok, AuthorizationCode.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization_code(
        %Scope{user: %User{id: user_id}},
        attrs,
        now \\ DateTime.utc_now()
      ) do
    issued_at = truncate(now)

    %AuthorizationCode{user_id: user_id}
    |> AuthorizationCode.create_changeset(attrs, issued_at)
    |> Repo.insert()
  end

  @doc """
  Consumes an authorization code issued to `client_id`, returning it with its
  user preloaded so the caller can check the PKCE verifier and redirect URI.

  One statement marks the code used, so a code is consumed at most once even
  under concurrent calls. Refused when the code is unknown, already used,
  expired, issued to another client, or belongs to a disabled user.
  """
  @spec consume_authorization_code(term(), term(), DateTime.t()) ::
          {:ok, AuthorizationCode.t()} | {:error, :invalid_grant}
  def consume_authorization_code(code, client_id, now \\ DateTime.utc_now())

  def consume_authorization_code(code, client_id, now)
      when is_binary(code) and is_binary(client_id) do
    hash = DeviceToken.hash_token(code)
    at = truncate(now)
    enabled_users = from(u in User, where: is_nil(u.disabled_at), select: u.id)

    query =
      from c in AuthorizationCode,
        where: c.code_hash == ^hash and c.client_id == ^client_id,
        where: is_nil(c.used_at) and c.expires_at > ^at,
        where: c.user_id in subquery(enabled_users),
        select: c

    query
    |> Repo.update_all(set: [used_at: at])
    |> consumed_code()
  end

  def consume_authorization_code(_code, _client_id, _now), do: {:error, :invalid_grant}

  defp consumed_code({1, [code]}), do: {:ok, Repo.preload(code, :user)}
  defp consumed_code({0, []}), do: {:error, :invalid_grant}

  defp share_lock_device(device_id) do
    from(d in Device, where: d.id == ^device_id, lock: "FOR SHARE")
    |> Repo.one()
  end

  defp update_lock_device(device_id) do
    from(d in Device, where: d.id == ^device_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp issue_for_locked(%Device{revoked_at: nil} = device, now) do
    if device |> TokenPairs.refresh_expiry(now) |> DateTime.compare(now) == :gt do
      family_id = Ecto.UUID.generate()
      TokenPairs.insert(device, family_id, now)
    else
      {:error, :expired}
    end
  end

  defp issue_for_locked(_revoked_or_missing, _now), do: {:error, :revoked}

  # Locks the device row first and the token row second: the same order as
  # revoke_device/4, which locks the device and then updates its tokens, so
  # the two can never deadlock. Holding the device lock also serializes the
  # rotation against a revocation and against every other rotation or
  # issue on the device, so a revocation's expiry sweep sees every token a
  # rotation committed, and the device the checks read is the locked row.
  defp rotate_in_transaction(hash, now, client_id) do
    Repo.transact(fn ->
      hash
      |> refresh_token_device_id()
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

  defp refresh_token_device_id(hash) do
    from(t in DeviceToken,
      where: t.token_hash == ^hash and t.kind == :refresh,
      select: t.device_id
    )
    |> Repo.one()
  end

  defp lock_device_with_user(nil), do: nil

  defp lock_device_with_user(device_id) do
    device_id
    |> update_lock_device()
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
      two_factor_overdue?(token.device.user, now) -> {:error, :invalid_token}
      true -> replace(token, now)
    end
  end

  defp two_factor_overdue?(user, now) do
    match?({:overdue, _deadline}, SecurityPolicies.two_factor_status_for_user(user, now))
  end

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
      organization_id: organization_id(device.user),
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

  @doc false
  # The Organization a device's audit rows are listed under, or nil.
  @spec organization_id(User.t()) :: pos_integer() | nil
  def organization_id(%User{} = user) do
    case Organizations.get_membership(user) do
      %{organization_id: organization_id} -> organization_id
      nil -> nil
    end
  end

  defp truncate(now), do: DateTime.truncate(now, :second)
end
