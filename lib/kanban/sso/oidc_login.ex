defmodule Kanban.SSO.OIDCLogin do
  @moduledoc """
  The OpenID Connect sign-in flow, called by `KanbanWeb.SSOController`
  through `Kanban.SSO`.

  `begin/2` finds the enabled OIDC connection of the Organization that
  verified the email domain, creates a flow (`Kanban.SSO.OIDC.new_flow/1`) and
  returns the authorization URL. The controller keeps the flow in the browser
  session, which is how `state`, `nonce` and the PKCE verifier are bound to
  that browser.

  `complete/3` takes the flow the controller has already removed from the
  session, so a flow is single-use: a replayed or second callback finds no
  flow. It then refuses an expired flow (older than ten minutes), an error
  returned by the identity provider, and a `state` that does not match
  (compared in constant time), exchanges the code with the PKCE verifier,
  validates the id_token against the flow's nonce, provisions the user
  (`Kanban.SSO.Provisioning`) and checks the paid gate.

  Every refusal is recorded as `:sso_login_refused` with a reason, and every
  success as `:sso_login`. The reasons are for the audit log only; the user is
  always shown one generic message, so a refusal reveals neither whether an
  account exists nor which Organization it belongs to.
  """

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.SSO
  alias Kanban.SSO.OIDC
  alias Kanban.SSO.Provisioning
  alias Kanban.SSO.SSOConnection

  @flow_ttl_seconds 600

  @doc """
  Starts a sign-in for an email `domain`. Returns `{:ok, flow, url}`, or
  `{:error, :not_available}` when no enabled connection serves the domain or
  its identity provider cannot be reached.
  """
  @spec begin(term(), String.t()) :: {:ok, map(), String.t()} | {:error, :not_available}
  def begin(domain, redirect_uri) when is_binary(redirect_uri) do
    with {:ok, connection} <- SSO.connection_for_domain(domain),
         {:ok, %{config: config}} <- OIDC.fetch_provider(connection) do
      flow = OIDC.new_flow(connection.id)
      {:ok, flow, OIDC.authorize_url(config, connection, redirect_uri, flow)}
    else
      _unavailable -> {:error, :not_available}
    end
  end

  @doc """
  Completes a sign-in from the identity provider's callback `params` and the
  flow removed from the session (`nil` when there was none). `opts` takes
  `:redirect_uri` (required) and `:ip` (recorded in the audit log only).
  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec complete(map() | nil, map(), keyword()) :: {:ok, User.t()} | {:error, atom()}
  def complete(flow, params, opts) when is_map(params) and is_list(opts) do
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)

    result =
      with {:ok, code} <- validate_callback(flow, params),
           {:ok, connection} <- fetch_connection(flow) do
        sign_in(connection, flow, code, redirect_uri)
      end

    audit(result, flow, opts)
  end

  defp validate_callback(flow, params) do
    with :ok <- check_flow(flow),
         :ok <- check_provider_error(params),
         :ok <- check_state(flow, params) do
      fetch_code(params)
    end
  end

  defp check_flow(%{
         "issued_at" => issued_at,
         "state" => state,
         "nonce" => nonce,
         "verifier" => v
       })
       when is_integer(issued_at) and is_binary(state) and is_binary(nonce) and is_binary(v) do
    if System.system_time(:second) - issued_at > @flow_ttl_seconds,
      do: {:error, :flow_expired},
      else: :ok
  end

  defp check_flow(_flow), do: {:error, :missing_flow}

  defp check_provider_error(%{"error" => _error}), do: {:error, :idp_error}
  defp check_provider_error(_params), do: :ok

  defp check_state(%{"state" => expected}, %{"state" => state}) when is_binary(state) do
    if Plug.Crypto.secure_compare(state, expected), do: :ok, else: {:error, :state_mismatch}
  end

  defp check_state(_flow, _params), do: {:error, :state_mismatch}

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp fetch_code(_params), do: {:error, :missing_code}

  defp fetch_connection(%{"connection_id" => id}) do
    case SSO.get_enabled_oidc_connection(id) do
      {:ok, connection} -> {:ok, connection}
      {:error, :not_found} -> {:error, :connection_unavailable}
    end
  end

  defp sign_in(%SSOConnection{} = connection, flow, code, redirect_uri) do
    with {:ok, claims} <- verified_claims(connection, flow, code, redirect_uri),
         {:ok, user, _outcome} <- Provisioning.provision(connection, claims),
         :ok <- paid_access(user) do
      {:ok, user, connection}
    else
      {:error, reason} -> {:error, reason, connection}
    end
  end

  defp verified_claims(connection, flow, code, redirect_uri) do
    with {:ok, provider} <- OIDC.fetch_provider(connection),
         {:ok, id_token} <-
           OIDC.exchange_code(provider.config, connection, code, flow["verifier"], redirect_uri) do
      OIDC.validate_id_token(provider, connection, id_token, flow["nonce"])
    end
  end

  defp paid_access(user) do
    case SSO.check_access(user, :controller) do
      :ok -> :ok
      {:error, {:plan_required, :sso}} -> {:error, :plan_required}
    end
  end

  defp audit({:ok, user, connection}, _flow, opts) do
    AuditLog.event(:sso_login,
      user_id: user.id,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: :oidc,
      ip: opts[:ip]
    )

    {:ok, user}
  end

  defp audit({:error, reason, connection}, _flow, opts) do
    AuditLog.event(:sso_login_refused,
      reason: reason,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: :oidc,
      ip: opts[:ip]
    )

    {:error, reason}
  end

  defp audit({:error, reason}, flow, opts) do
    AuditLog.event(:sso_login_refused,
      reason: reason,
      sso_connection_id: flow_connection_id(flow),
      protocol: :oidc,
      ip: opts[:ip]
    )

    {:error, reason}
  end

  defp flow_connection_id(%{"connection_id" => id}) when is_integer(id), do: id
  defp flow_connection_id(_flow), do: nil
end
