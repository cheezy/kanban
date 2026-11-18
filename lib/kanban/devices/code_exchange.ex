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
    2. The code is consumed (`Kanban.Devices.consume_authorization_code/3`):
       one statement marks it used, so of two concurrent exchanges exactly
       one gets it. It must have been issued to this `client_id`, be unused,
       unexpired and belong to an enabled user.
    3. The redirect URI must equal the one the code was issued for, and the
       verifier must hash to the code's S256 challenge
       (`Kanban.Devices.Pkce`).

  Steps 2 and 3 fail with the same `{:error, :invalid_grant}`. The code is
  already used up when step 3 fails, so a wrong verifier cannot be retried
  against the same code. The device and its token pair are then created in
  one transaction, and `:device_signed_in` is written once it commits.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.Pkce
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
  `opts` takes `:ip`, recorded on the audit row.
  """
  @spec exchange(grant(), map(), DateTime.t(), keyword()) ::
          {:ok, Devices.issued()} | {:error, :invalid_grant | Ecto.Changeset.t()}
  def exchange(grant, details, now, opts) when is_map(grant) and is_map(details) do
    at = DateTime.truncate(now, :second)

    with {:ok, attrs} <- device_details(details),
         {:ok, code} <- consume(grant, at),
         :ok <- verify_grant(code, grant) do
      sign_in(code, attrs, at, opts)
    end
  end

  defp consume(grant, now),
    do: Devices.consume_authorization_code(grant[:code], grant[:client_id], now)

  defp device_details(details) do
    case Device.details_changeset(details) do
      %Ecto.Changeset{valid?: true, changes: changes} -> {:ok, changes}
      changeset -> {:error, changeset}
    end
  end

  # The redirect URI comparison is exact, like the authorize page's.
  defp verify_grant(code, grant) do
    if code.redirect_uri === grant[:redirect_uri] and
         Pkce.verify(code.code_challenge, grant[:code_verifier]),
       do: :ok,
       else: {:error, :invalid_grant}
  end

  # The audit row is written only once the device and its tokens commit.
  defp sign_in(code, attrs, now, opts) do
    device_attrs = Map.merge(attrs, %{client_id: code.client_id, name: code.device_name})
    scope = Scope.for_user(code.user)

    Repo.transact(fn ->
      with {:ok, device} <- Devices.create_device(scope, device_attrs, now) do
        Devices.issue_tokens(device, now)
      end
    end)
    |> audit_signed_in(code.user, opts)
  end

  defp audit_signed_in({:ok, %{device: device}} = signed_in, user, opts) do
    AuditLog.event(:device_signed_in,
      user_id: user.id,
      organization_id: Devices.organization_id(user),
      device_id: device.id,
      platform: device.platform,
      device_class: device.device_class,
      app_version: device.app_version,
      ip: Keyword.get(opts, :ip)
    )

    signed_in
  end

  defp audit_signed_in(error, _user, _opts), do: error
end
