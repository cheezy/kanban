defmodule Kanban.Devices.AuthorizationCodes do
  @moduledoc """
  One-time OAuth authorization codes (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.1, §8), behind `Kanban.Devices.create_authorization_code/4` and
  `Kanban.Devices.consume_authorization_code/3`, and the code half of
  `Kanban.Devices.CodeExchange`.

  A code is issued when a signed-in person allows a device to sign in, lives
  60 seconds and is redeemed once. Redeeming locks the code's row first, so
  of two redemptions of one code exactly one gets it, and the other waits
  until the first has committed and then sees the code used.

  A password reset or change ends every code of the user's
  (`expire_unused/2`), and a code is issued only while the password the
  request signed in with is still the user's, under a share lock on the
  user row, so a code issued around a password change cannot sign a device
  in after it (D459).

  A code presented again after it was redeemed is a replay (RFC 6749
  §4.1.2, OAuth 2.0 Security BCP §4.2.4): the code leaked. The device the
  first redemption created is found by its token family, which is derived
  from the code (`family_id/1`), and `Kanban.Devices.CodeExchange` revokes
  it.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.SsoExemption
  alias Kanban.Repo

  @family_salt "oauth_authorization_code_family:"

  @doc """
  Issues a one-time authorization code for the scope's user at `now`. See
  `Kanban.Devices.create_authorization_code/4`.
  """
  @spec create(Scope.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AuthorizationCode.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{user: %User{id: user_id} = user} = scope, attrs, now, opts \\ []) do
    sso_organization_id = SsoExemption.authorized_organization_id(scope, opts[:sso_mark])

    Repo.transact(fn ->
      %AuthorizationCode{user_id: user_id, sso_organization_id: sso_organization_id}
      |> AuthorizationCode.create_changeset(attrs, DateTime.truncate(now, :second))
      |> refuse_after_password_change(user)
      |> Repo.insert()
    end)
  end

  # Locks the user row FOR SHARE, so a password reset or change in flight
  # commits first, and refuses the code when the password the scope was
  # loaded with is no longer the user's: the change has already expired
  # every code it could see, and this one would outlive it.
  defp refuse_after_password_change(changeset, %User{id: user_id, hashed_password: hashed}) do
    current =
      from(u in User, where: u.id == ^user_id, select: u.hashed_password, lock: "FOR SHARE")
      |> Repo.one()

    if current == hashed,
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :user_id, "changed its password")
  end

  @doc """
  Consumes an authorization code issued to `client_id`. See
  `Kanban.Devices.consume_authorization_code/3`. A replayed code is refused
  like any other here; only `Kanban.Devices.CodeExchange` acts on a replay.
  """
  @spec consume(term(), term(), DateTime.t()) ::
          {:ok, AuthorizationCode.t()} | {:error, :invalid_grant}
  def consume(code, client_id, now) do
    at = DateTime.truncate(now, :second)

    Repo.transact(fn ->
      code
      |> lock()
      |> redeem_locked(client_id, at)
      |> refuse_replay()
    end)
  end

  defp refuse_replay({:error, {:replayed, _code}}), do: {:error, :invalid_grant}
  defp refuse_replay(result), do: result

  @doc """
  Locks the row of the code whose plain value is `code` FOR UPDATE, inside
  the caller's transaction, waiting for a redemption in flight to commit.
  `nil` when there is no such code, or `code` is not a string.
  """
  @spec lock(term()) :: AuthorizationCode.t() | nil
  def lock(code) when is_binary(code) do
    hash = DeviceToken.hash_token(code)

    from(c in AuthorizationCode, where: c.code_hash == ^hash, lock: "FOR UPDATE")
    |> Repo.one()
  end

  def lock(_code), do: nil

  @doc """
  Redeems a locked code for `client_id` at `now`: marks it used and returns
  it with its user preloaded. The caller holds the row lock and owns the
  transaction.

  A code that was already used is `{:error, {:replayed, code}}`, whatever
  client presents it and however late. Every other refusal is
  `{:error, :invalid_grant}` and leaves the code unused: an unknown code, one
  issued to another client, an expired one, or one whose user is disabled.
  """
  @spec redeem_locked(AuthorizationCode.t() | nil, term(), DateTime.t()) ::
          {:ok, AuthorizationCode.t()}
          | {:error, :invalid_grant | {:replayed, AuthorizationCode.t()}}
  def redeem_locked(nil, _client_id, _now), do: {:error, :invalid_grant}

  def redeem_locked(%AuthorizationCode{used_at: %DateTime{}} = code, _client_id, _now),
    do: {:error, {:replayed, code}}

  def redeem_locked(%AuthorizationCode{} = code, client_id, now) do
    code = Repo.preload(code, :user)

    if redeemable?(code, client_id, now) do
      code
      |> Ecto.Changeset.change(used_at: now)
      |> Repo.update()
    else
      {:error, :invalid_grant}
    end
  end

  defp redeemable?(code, client_id, now) do
    code.client_id === client_id and DateTime.compare(code.expires_at, now) == :gt and
      is_nil(code.user.disabled_at)
  end

  @doc """
  Expires every unused, unexpired code of `user` at `now`, inside the
  caller's transaction, so none of them can sign a device in afterwards: a
  password reset or change runs this before it revokes the user's devices.

  The code's expiry is moved back to the second it was issued, which no
  redemption's clock can precede, rather than to `now`: an exchange that
  read its clock a second before the change, or on a node whose clock lags,
  still sees the code expired. It is expired rather than marked used, so
  presenting it later is an ordinary refusal and never a replay. A redemption in flight holds the
  code's row lock, so this waits for it to commit and then skips the code
  it used; the device that redemption created is committed by then, and
  the revocation that follows in the same transaction sees it.
  """
  @spec expire_unused(User.t(), DateTime.t()) :: :ok
  def expire_unused(%User{id: user_id}, now) do
    at = DateTime.truncate(now, :second)

    from(c in AuthorizationCode,
      where: c.user_id == ^user_id and is_nil(c.used_at) and c.expires_at > ^at,
      update: [set: [expires_at: c.inserted_at]]
    )
    |> Repo.update_all([])

    :ok
  end

  @doc """
  The token family of the device a code signs in: a UUID derived from the
  code's hash, so a replay of the code finds the tokens its first
  redemption issued, and every token rotated from them, without storing
  anything more. The salt keeps the family id from being the code's hash.
  """
  @spec family_id(AuthorizationCode.t()) :: Ecto.UUID.t()
  def family_id(%AuthorizationCode{code_hash: code_hash}) when is_binary(code_hash) do
    <<bytes::binary-size(16), _rest::binary>> = :crypto.hash(:sha256, @family_salt <> code_hash)
    {:ok, uuid} = Ecto.UUID.load(bytes)
    uuid
  end

  @doc """
  Locks, FOR UPDATE, the device a code signed in, found by `family_id/1`,
  with its user preloaded. `nil` when the code's redemption created no
  device, as when its verifier did not match, or the device is gone.
  """
  @spec lock_signed_in_device(AuthorizationCode.t()) :: Device.t() | nil
  def lock_signed_in_device(%AuthorizationCode{} = code) do
    family_id = family_id(code)
    device_ids = from(t in DeviceToken, where: t.family_id == ^family_id, select: t.device_id)

    from(d in Device, where: d.id in subquery(device_ids), lock: "FOR UPDATE", limit: 1)
    |> Repo.one()
    |> Repo.preload(:user)
  end
end
