defmodule Kanban.Devices do
  @moduledoc """
  Devices a person has signed in to Stride on, and their tokens
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  This is the public API the OAuth endpoints (`POST /oauth/token`,
  `POST /oauth/revoke`), the device plug and the device routes under
  `/api/me/devices` build on. Each function is a thin delegation to the
  module that holds its rules, so callers only ever name `Kanban.Devices`:

    * `Kanban.Devices.Issuance` creates a device and issues its first token
      pair (`create_device/3`, `issue_tokens/2`);
    * `Kanban.Devices.Lookup` reads devices: the one an access token
      belongs to and a person's own (`fetch_by_access_token/2`,
      `authenticate_access_token/2`, `fetch_signed_in_device/1`, `fetch_device/2`,
      `list_devices/1`, `list_devices_for/2`);
    * `Kanban.Devices.RefreshTokens` rotates a refresh token and signs a
      device out with one (`rotate_refresh_token/3`,
      `revoke_by_refresh_token/3`);
    * `Kanban.Devices.AuthorizationCodes` issues and consumes the one-time
      codes (`create_authorization_code/4`, `consume_authorization_code/3`),
      and `Kanban.Devices.CodeExchange` redeems one for a new device
      (`exchange_authorization_code/4`);
    * `Kanban.Devices.Revocation` revokes a device and announces it
      (`revoke_device/4`); `Kanban.Devices.CurrentDevice` is the app
      updating its own device (`update_current/4`);
      `Kanban.Devices.MemberDevices` is an org-admin listing and revoking a
      member's devices (`list_devices_for_member/2`,
      `revoke_member_device/3`, `revoke_all_for_member/3`);
      `Kanban.Devices.Activity` records when a device was last seen
      (`touch_last_seen/2`).

  The rules:

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
      **Replaying a used code** revokes the device its first exchange
      created, with every token issued from it (RFC 6749 §4.1.2).
    * **Refresh is refused** for a disabled user, a revoked device, and a
      user whose Organization requires two-factor once their grace period
      is over (`{:overdue, _}`), the same line the web gate draws. A member
      still in grace can refresh. The web gate's single sign-on exemption
      carries to a device allowed from a session signed in through the
      member's own Organization's single sign-on: the device records that
      Organization, and a refresh is exempt only while it is still the
      member's Organization, read again at each refresh
      (`Kanban.Devices.SsoExemption`).

  The security events are audited after their transaction commits, whoever
  the caller: `:device_signed_in` when a code exchange creates a device,
  `:device_refresh_reuse_detected` when refresh-token reuse revokes one, and
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

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Activity
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.AuthorizationCodes
  alias Kanban.Devices.CodeExchange
  alias Kanban.Devices.CurrentDevice
  alias Kanban.Devices.Device
  alias Kanban.Devices.Issuance
  alias Kanban.Devices.Lookup
  alias Kanban.Devices.MemberDevices
  alias Kanban.Devices.RefreshTokens
  alias Kanban.Devices.Revocation
  alias Kanban.Organizations

  @typedoc "A newly issued token pair: the plain values are shown only here."
  @type issued :: %{
          device: Device.t(),
          access_token: String.t(),
          access_token_expires_at: DateTime.t(),
          refresh_token: String.t(),
          refresh_token_expires_at: DateTime.t()
        }

  @doc """
  Creates a device for the scope's user, signed in at `now`. The person's
  first device also creates their push settings with its time zone
  (`Kanban.Notifications.ensure_push_settings_for_device/1`).
  """
  @spec create_device(Scope.t(), map(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_device(scope, attrs, now \\ DateTime.utc_now()), to: Issuance

  @doc """
  Issues a new access and refresh token for `device`, starting a new token
  family. Refused for a revoked device, and with `{:error, :expired}` once the
  device is 90 days past sign-in, when a refresh token would be born expired:
  the person must sign in again as a new device.
  """
  @spec issue_tokens(Device.t(), DateTime.t()) :: {:ok, issued()} | {:error, :revoked | :expired}
  defdelegate issue_tokens(device, now \\ DateTime.utc_now()), to: Issuance

  @doc """
  Finds the device an access token belongs to, with its user preloaded.

  Refused, with the same error whatever the cause, when the token is unknown,
  is not an access token, has expired, or belongs to a revoked device or a
  disabled user.
  """
  @spec fetch_by_access_token(term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :invalid_token}
  defdelegate fetch_by_access_token(token, now \\ DateTime.utc_now()), to: Lookup

  @doc """
  As `fetch_by_access_token/2`, but tells an access token that is known and
  only past its `expires_at`, on a device still signed in and a user still
  enabled, apart as `{:error, :expired_token}`. Every other refusal is
  `{:error, :invalid_token}`. One read either way. Only
  `KanbanWeb.Plugs.AuthenticateDeviceToken` uses the difference, to leave
  an app's routinely expired token out of the per-IP failure count; the
  response it sends is the same for both.
  """
  @spec authenticate_access_token(term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :expired_token | :invalid_token}
  defdelegate authenticate_access_token(token, now \\ DateTime.utc_now()), to: Lookup

  @doc """
  The device with id `id`, with its user preloaded, while it is still signed
  in: not revoked, and its user not disabled. Every other case, an unknown id
  included, is `{:error, :invalid_token}`. `KanbanWeb.UserSocket` reads the
  device a socket token names with it.
  """
  @spec fetch_signed_in_device(term()) :: {:ok, Device.t()} | {:error, :invalid_token}
  defdelegate fetch_signed_in_device(id), to: Lookup

  @doc """
  The PubSub topic a device's revocation is broadcast on, `"device:<id>"`:
  a socket whose `id/1` is this topic is closed when the device is revoked.
  """
  @spec device_topic(pos_integer()) :: String.t()
  defdelegate device_topic(device_id), to: Revocation, as: :topic

  @doc """
  Records that the device used the person API at `now`. Safe under
  concurrent requests and never moves `last_seen_at` backwards
  (`Kanban.Devices.Activity`).
  """
  @spec touch_last_seen(Device.t(), DateTime.t()) :: Device.t()
  defdelegate touch_last_seen(device, now \\ DateTime.utc_now()), to: Activity

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
  two-factor requirement (unless the device carries that Organization's
  single sign-on exemption, `Kanban.Devices.SsoExemption`), is
  `{:error, :invalid_token}` and leaves the token unused.

  `opts` takes `:ip`, the caller's address, recorded on the audit row, and
  `:client_id`, the client asking. When it is given, an unused token of a
  device signed in through another client is refused as `:invalid_token`
  and left unused: a refresh token works only for the app it was issued to.
  A used one is still reuse, whichever client presents it.
  """
  @spec rotate_refresh_token(term(), DateTime.t(), keyword()) ::
          {:ok, issued()} | {:error, :invalid_token | :reuse_detected}
  defdelegate rotate_refresh_token(token, now \\ DateTime.utc_now(), opts \\ []),
    to: RefreshTokens,
    as: :rotate

  @doc """
  Redeems an authorization code for a new device and its first token pair:
  the `authorization_code` grant of `POST /oauth/token`. A code presented
  again once redeemed is refused and revokes the device it created. See
  `Kanban.Devices.CodeExchange.exchange/4`.
  """
  @spec exchange_authorization_code(map(), map(), DateTime.t(), keyword()) ::
          {:ok, issued()} | {:error, :invalid_grant | Ecto.Changeset.t()}
  defdelegate exchange_authorization_code(grant, details, now \\ DateTime.utc_now(), opts \\ []),
    to: CodeExchange,
    as: :exchange

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
  defdelegate revoke_by_refresh_token(token, now \\ DateTime.utc_now(), opts \\ []),
    to: RefreshTokens,
    as: :revoke

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
  is `{:error, :revoked}`. With `report_unchanged: true`, a device found
  already revoked is `{:error, :already_revoked}`.

  A device that is already revoked is returned unchanged, and nothing is
  written or broadcast again. A device of another user is
  `{:error, :not_found}`. `now` must be a `DateTime`, so options are never
  mistaken for it.
  """
  @spec revoke_device(Scope.t(), Device.t(), DateTime.t(), keyword()) ::
          {:ok, Device.t()} | {:error, :not_found | :revoked | :already_revoked}
  def revoke_device(scope, device, now \\ DateTime.utc_now(), opts \\ [])

  def revoke_device(%Scope{} = scope, %Device{} = device, %DateTime{} = now, opts)
      when is_list(opts),
      do: Revocation.revoke_own(scope, device, truncate(now), opts)

  @doc """
  Gets one of the scope user's devices by id, revoked or not. Another
  user's device, or an id that names no device, is `{:error, :not_found}`.
  """
  @spec fetch_device(Scope.t(), pos_integer()) :: {:ok, Device.t()} | {:error, :not_found}
  defdelegate fetch_device(scope, id), to: Lookup

  @doc """
  Updates the device the app runs on, one of the scope user's, with `attrs`
  at `now`: its push token and push environment, locale, time zone and app
  version (`Kanban.Devices.Device.update_changeset/3`). A push token another
  of the person's devices holds moves to this one; one another person's
  device holds is refused.

  A device revoked while the request was in flight is `{:error, :revoked}`;
  another user's device is `{:error, :not_found}`; invalid attributes, and a
  push token another person's device holds, are `{:error, changeset}`. See
  `Kanban.Devices.CurrentDevice`.
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
  defdelegate list_devices_for(scope, device), to: Lookup

  @doc """
  Lists the scope user's devices that are not revoked, newest first.
  """
  @spec list_devices(Scope.t()) :: [Device.t()]
  defdelegate list_devices(scope), to: Lookup

  @doc """
  Subscribes the calling process to the scope user's device revocations,
  `{:device_revoked, device_id}`, whoever revokes them. See
  `Kanban.Devices.Revocation.user_topic/1`.
  """
  @spec subscribe_devices(Scope.t()) :: :ok | {:error, term()}
  def subscribe_devices(%Scope{user: %User{id: user_id}}), do: Revocation.subscribe_user(user_id)

  @doc """
  As `list_devices_for_member/2`, and on success also subscribes the calling
  process to that member's device revocations, so an org-admin's open list
  can be read again when one is revoked elsewhere. Undone by
  `unwatch_member_devices/1`.
  """
  @spec watch_member_devices(Scope.t(), term()) ::
          {:ok, [Device.t()]} | {:error, MemberDevices.error()}
  defdelegate watch_member_devices(scope, member_user_id), to: MemberDevices, as: :watch

  @doc "Unsubscribes the calling process from a member's device revocations."
  @spec unwatch_member_devices(pos_integer()) :: :ok
  defdelegate unwatch_member_devices(member_user_id), to: Revocation, as: :unsubscribe_user

  @doc """
  Lists the devices, not revoked, of the member with `member_user_id` of the
  scope user's Organization, newest first, for an org-admin.

  `{:error, :unauthorized}` unless the scope user is an enabled org-admin,
  `{:error, :not_found}` for a user outside their Organization or an id that
  names no one, and `{:error, :org_admin}` for another org-admin. See
  `Kanban.Devices.MemberDevices`.
  """
  @spec list_devices_for_member(Scope.t(), term()) ::
          {:ok, [Device.t()]} | {:error, MemberDevices.error()}
  defdelegate list_devices_for_member(scope, member_user_id), to: MemberDevices, as: :list

  @doc """
  Revokes, for an org-admin at `now`, the device with `device_id` of a member
  of their Organization, with the reason `:org_admin`. Refused as
  `list_devices_for_member/2` refuses; a device outside the Organization is
  `{:error, :not_found}`, and one that was already revoked is
  `{:error, :already_revoked}` and left unchanged. See
  `Kanban.Devices.MemberDevices`.
  """
  @spec revoke_member_device(Scope.t(), term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, MemberDevices.error()}
  def revoke_member_device(%Scope{} = scope, device_id, now \\ DateTime.utc_now()),
    do: MemberDevices.revoke_one(scope, device_id, truncate(now))

  @doc """
  Revokes, for an org-admin at `now`, every device of the member with
  `member_user_id` of their Organization, with the reason `:org_admin`, and
  returns the devices it revoked. Refused as `list_devices_for_member/2`
  refuses. See `Kanban.Devices.MemberDevices`.
  """
  @spec revoke_all_for_member(Scope.t(), term(), DateTime.t()) ::
          {:ok, [Device.t()]} | {:error, MemberDevices.error()}
  def revoke_all_for_member(%Scope{} = scope, member_user_id, now \\ DateTime.utc_now()),
    do: MemberDevices.revoke_all(scope, member_user_id, truncate(now))

  @doc """
  Issues a one-time authorization code for the scope's user at `now`. The
  plain code is in the returned struct's `code` field and nowhere else.

  `opts` takes `:sso_mark`, the web session's single sign-on mark
  (`KanbanWeb.UserAuth.OrganizationTwoFactorGate.sso_session_key/0`). When
  it names the scope's own Organization, so the web gate exempts the
  session from that Organization's two-factor requirement, the code records
  it in `sso_organization_id` and the device it signs in carries the
  exemption (`Kanban.Devices.SsoExemption`). It comes from the server's
  session, never from a request parameter.
  """
  @spec create_authorization_code(Scope.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AuthorizationCode.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_authorization_code(scope, attrs, now \\ DateTime.utc_now(), opts \\ []),
    to: AuthorizationCodes,
    as: :create

  @doc """
  Consumes an authorization code issued to `client_id`, returning it with its
  user preloaded so the caller can check the PKCE verifier and redirect URI.

  The code's row is locked while it is marked used, so a code is consumed at
  most once even under concurrent calls. Refused when the code is unknown,
  already used, expired, issued to another client, or belongs to a disabled
  user. Only `exchange_authorization_code/4` treats a used code as a replay.
  """
  @spec consume_authorization_code(term(), term(), DateTime.t()) ::
          {:ok, AuthorizationCode.t()} | {:error, :invalid_grant}
  defdelegate consume_authorization_code(code, client_id, now \\ DateTime.utc_now()),
    to: AuthorizationCodes,
    as: :consume

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
