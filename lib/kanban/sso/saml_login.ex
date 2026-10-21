defmodule Kanban.SSO.SAMLLogin do
  @moduledoc """
  The SAML 2.0 sign-in flow (W2246), called by `KanbanWeb.SSOController`
  (start) and `KanbanWeb.SAMLController` (assertion consumer service) through
  `Kanban.SSO`.

  `begin/2` finds the enabled SAML connection of the Organization that
  verified the email domain, stores a `Kanban.SSO.SAML.Request` (the
  AuthnRequest ID, a random RelayState token and the local return path) and
  returns the identity provider URL and the token. Nothing is kept in the
  session: the identity provider's POST is cross-site, so a SameSite=Lax
  browser does not send the session cookie with it. The controller binds the
  token to the browser with its own short-lived SameSite=None cookie instead,
  and `complete/3` refuses a response posted from any other browser as
  `:browser_mismatch`.

  `complete/3` takes the Organization id from the URL the response was posted
  to, so a response is only ever checked against that Organization's own
  connection and certificates. It finds the stored request by the RelayState
  token (scoped to that connection, unexpired), validates the response
  (`Kanban.SSO.SAML.validate_response/3`, which requires `InResponseTo` to name
  that request), then, in one transaction, records the assertion ID (a second
  use is refused as `:assertion_replayed` and audited as
  `:saml_assertion_replayed`) and marks the request consumed. Only then are
  the NameID and email handed to `Kanban.SSO.Provisioning` (the same rules as
  OIDC) and the paid gate checked. A sign-in that would link an existing
  account with two-factor turned on returns
  `{:two_factor_required, user, link, return_to}` instead, with nothing
  written or recorded beyond the consumed request and assertion ID; the
  controller asks for that account's code first (`Kanban.SSO.TwoFactorLink`).

  Every refusal is recorded as `:sso_login_refused` with a reason and
  `protocol: :saml`, and every success as `:sso_login`. The person is always
  shown one generic message.

  `purge_expired/2` removes expired requests and assertion IDs for
  `Kanban.Retention.PurgeWorker`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.Provisioning
  alias Kanban.SSO.SAML
  alias Kanban.SSO.SAML.AssertionID
  alias Kanban.SSO.SAML.Request
  alias Kanban.SSO.TwoFactorLink

  @request_ttl_seconds 600
  @max_relay_token_bytes 128

  @doc """
  Starts a SAML sign-in for an email `domain`, returning to `return_to` when
  it is a local path. Returns `{:ok, url, relay_token}` or
  `{:error, :not_available}`; the caller binds `relay_token` to the browser
  (see `complete/3`'s `:binding`).
  """
  @spec begin(term(), term()) :: {:ok, String.t(), String.t()} | {:error, :not_available}
  def begin(domain, return_to) do
    with {:ok, connection} <- SSO.saml_connection_for_domain(domain),
         {:ok, request} <- create_request(connection, local_path(return_to)) do
      sp = SAML.service_provider(connection.organization_id)

      {:ok, SAML.authn_request_url(connection, sp, request.request_id, request.relay_token),
       request.relay_token}
    else
      _unavailable -> {:error, :not_available}
    end
  end

  defp create_request(connection, return_to) do
    connection
    |> Request.new_changeset(%{
      request_id: SAML.new_request_id(),
      relay_token: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
      return_to: return_to,
      expires_at: :second |> DateTime.utc_now() |> DateTime.add(@request_ttl_seconds)
    })
    |> Repo.insert()
  end

  @doc """
  Completes a sign-in from the identity provider's POST `params`
  (`SAMLResponse`, `RelayState`) to the assertion consumer service of the
  Organization `organization_id` (the URL's path parameter). `opts` takes
  `:binding`, the RelayState the browser was given by `begin/2` (from a
  cookie), which must match the posted one so a response cannot be replayed
  into somebody else's browser (login CSRF), and `:ip` (recorded in the audit
  log only). Returns `{:ok, user, return_to}`
  (`return_to` is a local path or `nil`),
  `{:two_factor_required, user, link, return_to}` or `{:error, reason}`.
  """
  @spec complete(term(), map(), keyword()) ::
          {:ok, User.t(), String.t() | nil}
          | {:two_factor_required, User.t(), TwoFactorLink.link(), String.t() | nil}
          | {:error, atom()}
  def complete(organization_id, params, opts) when is_map(params) and is_list(opts) do
    case fetch_connection(organization_id) do
      {:ok, connection} ->
        connection
        |> sign_in(params, opts[:binding])
        |> audit(connection, opts)

      {:error, reason} ->
        AuditLog.event(:sso_login_refused, reason: reason, protocol: :saml, ip: opts[:ip])
        {:error, reason}
    end
  end

  defp fetch_connection(organization_id) do
    with {id, ""} <- organization_id |> to_string() |> Integer.parse(),
         {:ok, connection} <- SSO.get_enabled_saml_connection(id) do
      {:ok, connection}
    else
      _missing -> {:error, :connection_unavailable}
    end
  end

  defp sign_in(connection, params, binding) do
    with {:ok, request} <- fetch_request(connection, params["RelayState"]),
         {:ok, result} <- validate(connection, request, params["SAMLResponse"]),
         :ok <- accept(connection, request, result, binding) do
      provision(connection, result, request)
    end
  end

  defp validate(connection, request, saml_response) do
    SAML.validate_response(saml_response, connection, %{
      service_provider: SAML.service_provider(connection.organization_id),
      request_id: request.request_id
    })
  end

  defp provision(connection, result, request) do
    case Provisioning.provision(connection, claims(result)) do
      {:ok, user, _outcome} ->
        with :ok <- paid_access(user), do: {:ok, user, local_path(request.return_to)}

      {:two_factor_required, user} ->
        {:two_factor_required, user, TwoFactorLink.link(connection, result.subject),
         local_path(request.return_to)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_request(connection, token)
       when is_binary(token) and byte_size(token) in 1..@max_relay_token_bytes do
    case Repo.get_by(Request, relay_token: token, sso_connection_id: connection.id) do
      nil ->
        {:error, :missing_request}

      %Request{expires_at: expires_at} = request ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt,
          do: {:ok, request},
          else: {:error, :request_expired}
    end
  end

  defp fetch_request(_connection, _token), do: {:error, :missing_request}

  defp accept(connection, request, result, binding) do
    with :ok <- accept_once(connection, request, result) do
      check_binding(binding, request.relay_token)
    end
  end

  # Records the assertion ID and consumes the request together, so an
  # assertion is accepted at most once and a request answers at most one.
  defp accept_once(connection, request, result) do
    Repo.transact(fn ->
      with {:ok, _recorded} <- record_assertion(connection, result),
           :ok <- consume(request) do
        {:ok, :accepted}
      end
    end)
    |> case do
      {:ok, :accepted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_assertion(connection, result) do
    case connection
         |> AssertionID.new_changeset(result.assertion_id, result.expires_at)
         |> Repo.insert() do
      {:ok, recorded} -> {:ok, recorded}
      {:error, changeset} -> {:error, record_error(changeset)}
    end
  end

  # Only the unique (connection, assertion ID) constraint means a replay.
  defp record_error(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end),
      do: :assertion_replayed,
      else: :invalid_response
  end

  defp consume(%Request{id: id}) do
    case from(r in Request, where: r.id == ^id and is_nil(r.consumed_at))
         |> Repo.update_all(set: [consumed_at: DateTime.utc_now(:second)]) do
      {1, _rows} -> :ok
      {_count, _rows} -> {:error, :request_used}
    end
  end

  # Checked after the assertion is recorded, so a replay is always recorded
  # as one whichever browser posts it.
  defp check_binding(binding, relay_token) when is_binary(binding) do
    if Plug.Crypto.secure_compare(binding, relay_token),
      do: :ok,
      else: {:error, :browser_mismatch}
  end

  defp check_binding(_binding, _relay_token), do: {:error, :browser_mismatch}

  # Only a fully validated assertion reaches this point, and the email gate in
  # Kanban.SSO.Provisioning still requires a domain the Organization verified.
  defp claims(result) do
    %{
      "sub" => result.subject,
      "email" => result.email,
      "email_verified" => true,
      "name" => result.name
    }
  end

  defp paid_access(user) do
    case SSO.check_access(user, :controller) do
      :ok -> :ok
      {:error, {:plan_required, :sso}} -> {:error, :plan_required}
    end
  end

  # The audit calls name their action literally so the telemetry source scan
  # (test/kanban/telemetry/emit_sites_test.exs) finds them.
  # Nothing is linked before the challenge, so there is nothing to record.
  defp audit({:two_factor_required, _user, _link, _return_to} = pending, _connection, _opts),
    do: pending

  defp audit({:ok, user, return_to}, connection, opts) do
    AuditLog.event(:sso_login,
      user_id: user.id,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: :saml,
      ip: opts[:ip]
    )

    {:ok, user, return_to}
  end

  defp audit({:error, :assertion_replayed}, connection, opts) do
    AuditLog.event(:saml_assertion_replayed,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      ip: opts[:ip]
    )

    refused(:assertion_replayed, connection, opts)
  end

  defp audit({:error, reason}, connection, opts), do: refused(reason, connection, opts)

  defp refused(reason, connection, opts) do
    AuditLog.event(:sso_login_refused,
      reason: reason,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: :saml,
      ip: opts[:ip]
    )

    {:error, reason}
  end

  @doc """
  `return_to` when it is a path on this site (`/boards`, never
  `//host`, `/\\host` or an absolute URL), otherwise `nil`.
  """
  @spec local_path(term()) :: String.t() | nil
  def local_path("/" <> rest = path) when byte_size(path) <= 2048 do
    cond do
      String.starts_with?(rest, ["/", "\\"]) -> nil
      String.match?(path, ~r/[\x00-\x20\\]/) -> nil
      match?(%URI{scheme: nil, host: nil}, URI.parse(path)) -> path
      true -> nil
    end
  end

  def local_path(_return_to), do: nil

  # --- retention -----------------------------------------------------------------

  @doc """
  Removes SAML requests and assertion IDs that expired before `now`,
  `batch_size` rows per statement. Returns the number of rows removed.
  """
  @spec purge_expired(DateTime.t(), pos_integer()) :: non_neg_integer()
  def purge_expired(%DateTime{} = now, batch_size) when is_integer(batch_size) and batch_size > 0,
    do: purge(Request, now, batch_size, 0) + purge(AssertionID, now, batch_size, 0)

  defp purge(schema, now, batch_size, removed) do
    ids = from(r in schema, where: r.expires_at < ^now, select: r.id, limit: ^batch_size)

    case from(r in schema, where: r.id in subquery(ids)) |> Repo.delete_all() do
      {count, _rows} when count < batch_size -> removed + count
      {count, _rows} -> purge(schema, now, batch_size, removed + count)
    end
  end
end
