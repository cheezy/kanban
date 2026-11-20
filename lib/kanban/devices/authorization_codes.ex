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
  def create(%Scope{user: %User{id: user_id}} = scope, attrs, now, opts \\ []) do
    sso_organization_id = SsoExemption.authorized_organization_id(scope, opts[:sso_mark])

    %AuthorizationCode{user_id: user_id, sso_organization_id: sso_organization_id}
    |> AuthorizationCode.create_changeset(attrs, DateTime.truncate(now, :second))
    |> Repo.insert()
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
