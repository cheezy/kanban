defmodule Kanban.Devices.CodeExchange do
  @moduledoc """
  The `authorization_code` grant of `POST /oauth/token`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1): an app trades the
  code the authorize page issued, and the PKCE verifier only it knows, for a
  new device and that device's first access and refresh token.

  The checks run in this order, and nothing is created until all of them
  pass:

    1. The device details the app sends are checked
       (`Kanban.Devices.Device.details_changeset/1`). A bad detail is
       `{:error, changeset}` and leaves the code unused, so the app can retry.
    2. The code's row is locked and the code redeemed
       (`Kanban.Devices.AuthorizationCodes.redeem_locked/3`): it must have
       been issued to this `client_id`, be unused, unexpired and belong to an
       enabled user. Of two concurrent exchanges exactly one gets it; the
       other waits on the row lock until the first commits.
    3. The redirect URI must equal the one the code was issued for, and the
       verifier must hash to the code's S256 challenge
       (`Kanban.Devices.Pkce`).

  Steps 2 and 3 fail with the same `{:error, :invalid_grant}`. The code is
  already used up when step 3 fails, so a wrong verifier cannot be retried
  against the same code. Steps 2 and 3, the device and its token pair all
  run in one transaction, and once it commits `:device_signed_in` is written
  and `[:kanban, :device, :signed_in]` emitted, with the platform and device
  class only. The token pair's family is derived from the code
  (`Kanban.Devices.AuthorizationCodes.family_id/1`). The device takes the
  code's `sso_organization_id`, the single sign-on mark of the web session
  that allowed it (`Kanban.Devices.SsoExemption`).

  ## A replayed code

  A code presented again once it was redeemed means it leaked (RFC 6749
  §4.1.2, OAuth 2.0 Security BCP §4.2.4). The replay is refused with
  `{:error, :invalid_grant}`, like any bad code, and it revokes the device
  the first exchange created, with every token issued from the code and
  rotated since, whichever client presents it and however late, as long as
  the code's row is kept. The revocation commits although the call fails,
  and is announced with the reason `:reuse_detected`
  (`Kanban.Devices.Revocation.announce/2`). Because the first exchange holds
  the code's row lock until its device commits, a replay racing it waits and
  then revokes that device: it never sees the code used with no device yet.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.AuthorizationCodes
  alias Kanban.Devices.Device
  alias Kanban.Devices.Issuance
  alias Kanban.Devices.Pkce
  alias Kanban.Devices.Revocation
  alias Kanban.Repo

  @typedoc "What the app proves it holds: the code, its client, redirect URI and verifier."
  @type grant :: %{
          code: term(),
          client_id: term(),
          redirect_uri: term(),
          code_verifier: term()
        }

  @doc """
  Redeems `grant` for a new device described by `details`, at `now`.

  `details` holds the device fields the app sends (`platform`,
  `device_class`, `model`, `os_version`, `app_version`, `locale`,
  `time_zone` and `approval_public_key`), with string or atom keys. The
  device's name and client id come from the code, never from `details`.
  `opts` takes `:ip`, recorded on the audit rows.
  """
  @spec exchange(grant(), map(), DateTime.t(), keyword()) ::
          {:ok, Devices.issued()} | {:error, :invalid_grant | Ecto.Changeset.t()}
  def exchange(grant, details, now, opts) when is_map(grant) and is_map(details) do
    at = DateTime.truncate(now, :second)

    with {:ok, attrs} <- device_details(details) do
      grant
      |> redeem(attrs, at)
      |> announce(opts)
    end
  end

  defp device_details(details) do
    case Device.details_changeset(details) do
      %Ecto.Changeset{valid?: true, changes: changes} -> {:ok, changes}
      changeset -> {:error, changeset}
    end
  end

  defp redeem(grant, attrs, now) do
    Repo.transact(fn ->
      grant[:code]
      |> AuthorizationCodes.lock()
      |> AuthorizationCodes.redeem_locked(grant[:client_id], now)
      |> sign_in_or_revoke(grant, attrs, now)
    end)
  end

  # A redeemed code stays used when the grant then fails, so the refusal is
  # returned as {:ok, _} for Repo.transact to commit the mark; a replay's
  # revocation commits the same way.
  defp sign_in_or_revoke({:ok, code}, grant, attrs, now) do
    if valid_grant?(code, grant),
      do: sign_in(code, attrs, now),
      else: {:ok, :invalid_grant}
  end

  defp sign_in_or_revoke({:error, {:replayed, code}}, _grant, _attrs, now) do
    code
    |> AuthorizationCodes.lock_signed_in_device()
    |> Revocation.revoke_locked(nil, now)
    |> replayed()
  end

  defp sign_in_or_revoke({:error, :invalid_grant} = refused, _grant, _attrs, _now), do: refused

  # A code whose redemption created no device, as when its verifier did not
  # match, has nothing to revoke.
  defp replayed({:ok, revocation}), do: {:ok, {:replayed, revocation}}
  defp replayed({:error, :not_found}), do: {:ok, :invalid_grant}

  # The redirect URI comparison is exact, like the authorize page's.
  defp valid_grant?(code, grant) do
    code.redirect_uri === grant[:redirect_uri] and
      Pkce.verify(code.code_challenge, grant[:code_verifier])
  end

  defp sign_in(code, attrs, now) do
    device_attrs = Map.merge(attrs, %{client_id: code.client_id, name: code.device_name})
    family_id = AuthorizationCodes.family_id(code)

    scope = Scope.for_user(code.user)

    sso = [sso_organization_id: code.sso_organization_id]

    with {:ok, device} <- Issuance.create_device(scope, device_attrs, now, sso),
         {:ok, issued} <- Issuance.issue_tokens(device, now, family_id) do
      {:ok, {:signed_in, issued, code.user}}
    end
  end

  # The audit rows and the events are written only once the transaction
  # commits.
  defp announce({:ok, {:signed_in, issued, user}}, opts) do
    audit_signed_in(issued.device, user, opts)
    {:ok, issued}
  end

  # A device revoked before the replay comes back :unchanged and is not
  # announced again.
  defp announce({:ok, {:replayed, {_revoked_or_unchanged, device} = revocation}}, opts) do
    Revocation.announce({:ok, revocation},
      owner: device.user,
      user_id: device.user_id,
      reason: :reuse_detected,
      ip: Keyword.get(opts, :ip)
    )

    {:error, :invalid_grant}
  end

  defp announce({:ok, :invalid_grant}, _opts), do: {:error, :invalid_grant}
  defp announce({:error, _reason} = error, _opts), do: error

  defp audit_signed_in(device, user, opts) do
    AuditLog.event(:device_signed_in,
      user_id: user.id,
      organization_id: Devices.organization_id(user),
      device_id: device.id,
      platform: device.platform,
      device_class: device.device_class,
      app_version: device.app_version,
      ip: Keyword.get(opts, :ip)
    )

    Kanban.Telemetry.emit(
      [:kanban, :device, :signed_in],
      %{count: 1},
      %{platform: label(device.platform), device_class: label(device.device_class)}
    )
  end

  defp label(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label(_value), do: nil
end
