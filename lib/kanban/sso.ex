defmodule Kanban.SSO do
  @moduledoc """
  Single sign-on per Organization (W2245).

  An Organization's org-admins prove ownership of email domains through a DNS
  TXT record (`Kanban.SSO.OrganizationDomain`,
  `Kanban.SSO.DomainVerification`) and register one OpenID Connect identity
  provider (`Kanban.SSO.SSOConnection`). A person whose email domain an
  Organization has verified can then sign in through that provider; the
  protocol lives in `Kanban.SSO.OIDC`, the sign-in orchestration in
  `Kanban.SSO.OIDCLogin`, and the just-in-time account and membership rules in
  `Kanban.SSO.Provisioning` (shared by OIDC, SAML and, later, SCIM).

  An Organization may also register one SAML 2.0 identity provider (W2246):
  the protocol lives in `Kanban.SSO.SAML` and the sign-in in
  `Kanban.SSO.SAMLLogin`. It passes the same paid gate and the same
  provisioning rules; its sign-on URL is only a browser redirect target, so
  the server never fetches it.

  ## Who may change what

  Every write takes the acting user and the Organization id, which callers
  read from the actor's own membership, never from request params. A write is
  allowed only for an enabled org-admin of that Organization with paid access
  (`Kanban.Plans`, feature `:sso`), all read from the database at call time;
  anyone else gets `{:error, :unauthorized}` and nothing is written. Domain and
  connection lookups are scoped to the Organization id, so another
  Organization's row is `:not_found`.

  A verified domain is checked again every day (`Kanban.SSO.DomainRecheck`,
  decided 2026-10-21) and stops being verified when its TXT record has been
  missing for three checks in a row.

  ## Outbound requests

  The issuer and the JWKS and token endpoints its discovery document names
  are checked by `Kanban.Webhooks.UrlGuard` before they are saved or fetched,
  so an org-admin cannot point the server at its own network, and each fetch
  is pinned to the address that was checked (`pinned_request/1`).
  `allow_private_issuers?/0`
  (`config :kanban, Kanban.SSO, allow_private_issuers: true`, development
  only) turns that check off for a local identity provider.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.OIDCLogin
  alias Kanban.SSO.OrganizationDomain
  alias Kanban.SSO.SAMLLogin
  alias Kanban.SSO.SSOConnection
  alias Kanban.SSO.TwoFactorLink
  alias Kanban.SSO.UserIdentity
  alias Kanban.Webhooks.UrlGuard

  # --- configuration -----------------------------------------------------------

  @doc """
  True only where the configuration allows a private or plain-http issuer
  (development, for a local identity provider). Read at call time.
  """
  @spec allow_private_issuers?() :: boolean()
  def allow_private_issuers? do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:allow_private_issuers, false) == true
  end

  @doc """
  Checks that `url` may be fetched: `Kanban.Webhooks.UrlGuard.check/2`, unless
  `allow_private_issuers?/0`. Returns `:ok` or `{:error, :unsafe_url}`.
  """
  @spec guard_url(term()) :: :ok | {:error, :unsafe_url}
  def guard_url(url) do
    case pinned_request(url) do
      {:ok, _options} -> :ok
      {:error, :unsafe_url} -> {:error, :unsafe_url}
    end
  end

  @doc """
  Checks `url` as `guard_url/1` does and returns the Req options that send a
  request to an address the check approved: the URL's host is replaced with
  that address (IPv4 first), and the original host name goes in the `host`
  header and in `connect_options` for TLS SNI and certificate verification. A
  DNS change between the check and the connection (DNS rebinding) therefore
  cannot reach another address. With `allow_private_issuers?/0` the URL is used
  as it is. Returns `{:ok, options}` or `{:error, :unsafe_url}`.
  """
  @spec pinned_request(term()) :: {:ok, keyword()} | {:error, :unsafe_url}
  def pinned_request(url) do
    if allow_private_issuers?() do
      {:ok, [url: url]}
    else
      case UrlGuard.check(url, allow_http: false, resolver: url_resolver()) do
        {:ok, %{uri: uri, addresses: addresses}} -> {:ok, pinned_options(uri, addresses)}
        {:error, _reason} -> {:error, :unsafe_url}
      end
    end
  end

  defp pinned_options(%URI{} = uri, addresses) do
    address = Enum.find(addresses, &(tuple_size(&1) == 4)) || List.first(addresses)

    [
      url: URI.to_string(%URI{uri | host: address |> :inet.ntoa() |> to_string()}),
      headers: [{"host", host_header(uri)}],
      connect_options: [hostname: uri.host]
    ]
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp url_resolver do
    case Application.get_env(:kanban, __MODULE__, [])[:resolver] do
      {module, function} -> &apply(module, function, [&1])
      nil -> &UrlGuard.resolve/1
    end
  end

  # --- access ------------------------------------------------------------------

  @doc """
  The paid gate for single sign-on: `Kanban.Plans.check_user/3` with feature
  `:sso`. Returns `:ok` or `{:error, {:plan_required, :sso}}`.
  """
  @spec check_access(User.t() | Kanban.Accounts.Scope.t() | nil, Plans.surface()) ::
          :ok | {:error, {:plan_required, :sso}}
  def check_access(user_or_scope, surface),
    do: Plans.check_user(user_or_scope, :sso, surface: surface)

  # The org-admin check every write runs, read from the database.
  defp authorize(%User{id: id}, organization_id) do
    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization_id),
         :ok <- check_access(actor, :context) do
      {:ok, actor}
    else
      _refused -> {:error, :unauthorized}
    end
  end

  # --- domains -----------------------------------------------------------------

  @doc "The Organization's claimed domains, oldest first."
  @spec list_domains(integer()) :: [OrganizationDomain.t()]
  def list_domains(organization_id) when is_integer(organization_id) do
    from(d in OrganizationDomain,
      where: d.organization_id == ^organization_id,
      order_by: [asc: d.inserted_at, asc: d.id]
    )
    |> Repo.all()
  end

  @doc "A changeset for the add-domain form."
  @spec change_domain(map()) :: Ecto.Changeset.t()
  def change_domain(attrs \\ %{}), do: OrganizationDomain.create_changeset(0, attrs)

  @doc """
  Claims `domain` for the Organization, unverified. A domain another
  Organization has already verified is refused with `:domain_taken`.
  """
  @spec add_domain(User.t(), integer(), map()) ::
          {:ok, OrganizationDomain.t()}
          | {:error, :unauthorized | :domain_taken | Ecto.Changeset.t()}
  def add_domain(%User{} = actor, organization_id, attrs) when is_map(attrs) do
    with {:ok, _actor} <- authorize(actor, organization_id) do
      changeset = OrganizationDomain.create_changeset(organization_id, attrs)

      if changeset.valid? and verified_elsewhere?(changeset.changes.domain, organization_id),
        do: {:error, :domain_taken},
        else: Repo.insert(changeset)
    end
  end

  defp verified_elsewhere?(domain, organization_id) do
    from(d in OrganizationDomain,
      where:
        d.domain == ^domain and d.organization_id != ^organization_id and
          not is_nil(d.verified_at)
    )
    |> Repo.exists?()
  end

  @doc """
  Verifies one of the Organization's domains: passes only when its TXT record
  is published (`Kanban.SSO.DomainVerification.check/2`, whose options this
  takes), and refuses with `:domain_taken` when another Organization verified
  the domain first. Records `:organization_domain_verified`.
  """
  @spec verify_domain(User.t(), integer(), term(), keyword()) ::
          {:ok, OrganizationDomain.t()}
          | {:error, :unauthorized | :not_found | :record_not_found | :domain_taken}
  def verify_domain(%User{} = actor, organization_id, domain_id, opts \\ []) do
    with {:ok, actor} <- authorize(actor, organization_id),
         {:ok, domain} <- fetch_domain(organization_id, domain_id),
         :ok <- DomainVerification.check(domain, opts),
         {:ok, verified} <- mark_verified(domain) do
      AuditLog.event(:organization_domain_verified,
        user_id: actor.id,
        organization_id: organization_id,
        domain: verified.domain
      )

      {:ok, verified}
    end
  end

  defp mark_verified(%OrganizationDomain{verified_at: %DateTime{}} = domain), do: {:ok, domain}

  defp mark_verified(domain) do
    case domain |> OrganizationDomain.verify_changeset(DateTime.utc_now()) |> Repo.update() do
      {:ok, verified} -> {:ok, verified}
      {:error, %Ecto.Changeset{}} -> {:error, :domain_taken}
    end
  end

  @doc "Removes one of the Organization's domains."
  @spec remove_domain(User.t(), integer(), term()) ::
          {:ok, OrganizationDomain.t()} | {:error, :unauthorized | :not_found}
  def remove_domain(%User{} = actor, organization_id, domain_id) do
    with {:ok, _actor} <- authorize(actor, organization_id),
         {:ok, domain} <- fetch_domain(organization_id, domain_id) do
      Repo.delete(domain)
    end
  end

  defp fetch_domain(organization_id, domain_id) do
    with {id, ""} <- domain_id |> to_string() |> Integer.parse(),
         %OrganizationDomain{} = domain <-
           Repo.get_by(OrganizationDomain, id: id, organization_id: organization_id) do
      {:ok, domain}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "True when the Organization has verified `domain` (already normalized)."
  @spec domain_verified_by?(integer(), String.t()) :: boolean()
  def domain_verified_by?(organization_id, domain) when is_binary(domain) do
    from(d in OrganizationDomain,
      where:
        d.organization_id == ^organization_id and d.domain == ^domain and
          not is_nil(d.verified_at)
    )
    |> Repo.exists?()
  end

  # --- connections -------------------------------------------------------------

  @doc "The Organization's OIDC connection, or `nil`."
  @spec get_oidc_connection(integer()) :: SSOConnection.t() | nil
  def get_oidc_connection(organization_id) when is_integer(organization_id) do
    Repo.get_by(SSOConnection, organization_id: organization_id, protocol: :oidc)
  end

  @doc "A changeset for the OIDC connection form."
  @spec change_oidc_connection(SSOConnection.t() | nil, map()) :: Ecto.Changeset.t()
  def change_oidc_connection(connection, attrs \\ %{})

  def change_oidc_connection(nil, attrs),
    do: SSOConnection.oidc_changeset(%SSOConnection{protocol: :oidc}, attrs)

  def change_oidc_connection(%SSOConnection{} = connection, attrs),
    do: SSOConnection.oidc_changeset(connection, attrs)

  @doc """
  Creates or updates the Organization's OIDC connection. The issuer must pass
  `guard_url/1`. Records `:sso_connection_updated` with whether the issuer and
  the client credentials changed, never their values.
  """
  @spec save_oidc_connection(User.t(), integer(), map()) ::
          {:ok, SSOConnection.t()}
          | {:error, :unauthorized | :unsafe_issuer | Ecto.Changeset.t()}
  def save_oidc_connection(%User{} = actor, organization_id, attrs) when is_map(attrs) do
    with {:ok, actor} <- authorize(actor, organization_id),
         changeset = oidc_connection_changeset(actor, organization_id, attrs),
         :ok <- guard_issuer(changeset),
         {:ok, connection} <- Repo.insert_or_update(changeset) do
      audit_connection_update(actor, connection, changeset, client_changed?(changeset))
      {:ok, connection}
    end
  end

  defp client_changed?(%Ecto.Changeset{changes: changes}),
    do: Map.has_key?(changes, :client_id) or Map.has_key?(changes, :client_secret)

  defp oidc_connection_changeset(actor, organization_id, attrs) do
    (get_oidc_connection(organization_id) ||
       %SSOConnection{organization_id: organization_id, protocol: :oidc})
    |> SSOConnection.oidc_changeset(attrs)
    |> Ecto.Changeset.put_change(:updated_by_id, actor.id)
  end

  defp guard_issuer(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, %{changeset | action: :validate}}

  defp guard_issuer(changeset) do
    case guard_url(Ecto.Changeset.get_field(changeset, :issuer)) do
      :ok -> :ok
      {:error, :unsafe_url} -> {:error, :unsafe_issuer}
    end
  end

  # One audit shape for both protocols; the protocol comes from the row.
  defp audit_connection_update(actor, connection, changeset, credentials_changed) do
    AuditLog.event(:sso_connection_updated,
      user_id: actor.id,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: connection.protocol,
      enabled: connection.enabled,
      issuer_changed: Map.has_key?(changeset.changes, :issuer),
      credentials_changed: credentials_changed
    )
  end

  @doc """
  The enabled OIDC connection of the Organization that verified `domain`, or
  `{:error, :not_found}`.
  """
  @spec connection_for_domain(term()) :: {:ok, SSOConnection.t()} | {:error, :not_found}
  def connection_for_domain(domain), do: enabled_connection_for_domain(domain, :oidc)

  @doc """
  The enabled SAML connection of the Organization that verified `domain`, or
  `{:error, :not_found}`.
  """
  @spec saml_connection_for_domain(term()) :: {:ok, SSOConnection.t()} | {:error, :not_found}
  def saml_connection_for_domain(domain), do: enabled_connection_for_domain(domain, :saml)

  defp enabled_connection_for_domain(domain, protocol) do
    with {:ok, domain} <- OrganizationDomain.normalize(domain),
         %SSOConnection{} = connection <-
           domain |> enabled_connection_query(protocol) |> Repo.one() do
      {:ok, connection}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp enabled_connection_query(domain, protocol) do
    from(c in SSOConnection,
      join: d in OrganizationDomain,
      on: d.organization_id == c.organization_id,
      where:
        d.domain == ^domain and not is_nil(d.verified_at) and c.protocol == ^protocol and
          c.enabled,
      limit: 1
    )
  end

  @doc "The enabled OIDC connection with `id`, or `{:error, :not_found}`."
  @spec get_enabled_oidc_connection(term()) :: {:ok, SSOConnection.t()} | {:error, :not_found}
  def get_enabled_oidc_connection(id) when is_integer(id) do
    case Repo.get_by(SSOConnection, id: id, protocol: :oidc, enabled: true) do
      %SSOConnection{} = connection -> {:ok, connection}
      nil -> {:error, :not_found}
    end
  end

  def get_enabled_oidc_connection(_id), do: {:error, :not_found}

  # --- SAML connections ----------------------------------------------------------

  @doc "The Organization's SAML connection, or `nil`."
  @spec get_saml_connection(integer()) :: SSOConnection.t() | nil
  def get_saml_connection(organization_id) when is_integer(organization_id) do
    Repo.get_by(SSOConnection, organization_id: organization_id, protocol: :saml)
  end

  @doc "A changeset for the SAML connection form."
  @spec change_saml_connection(SSOConnection.t() | nil, map()) :: Ecto.Changeset.t()
  def change_saml_connection(connection, attrs \\ %{})

  def change_saml_connection(nil, attrs),
    do: SSOConnection.saml_changeset(%SSOConnection{protocol: :saml}, attrs)

  def change_saml_connection(%SSOConnection{} = connection, attrs),
    do: SSOConnection.saml_changeset(connection, attrs)

  @doc """
  Creates or updates the Organization's SAML connection. Records
  `:sso_connection_updated` with whether the IdP entity id and the
  certificates changed, never their values.
  """
  @spec save_saml_connection(User.t(), integer(), map()) ::
          {:ok, SSOConnection.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def save_saml_connection(%User{} = actor, organization_id, attrs) when is_map(attrs) do
    with {:ok, actor} <- authorize(actor, organization_id),
         existing = get_saml_connection(organization_id),
         changeset = saml_connection_changeset(actor, existing, organization_id, attrs),
         {:ok, connection} <- Repo.insert_or_update(changeset) do
      audit_saml_save(actor, existing, connection, changeset)
      {:ok, connection}
    end
  end

  defp audit_saml_save(actor, existing, connection, changeset) do
    changed = certificates(connection) != certificates(existing)
    audit_connection_update(actor, connection, changeset, changed)
  end

  defp saml_connection_changeset(actor, existing, organization_id, attrs) do
    (existing || %SSOConnection{organization_id: organization_id, protocol: :saml})
    |> SSOConnection.saml_changeset(attrs)
    |> Ecto.Changeset.put_change(:updated_by_id, actor.id)
  end

  defp certificates(%SSOConnection{settings: %{"certificates" => certificates}}), do: certificates
  defp certificates(_connection), do: nil

  @doc "The enabled SAML connection of the Organization `organization_id`, or `{:error, :not_found}`."
  @spec get_enabled_saml_connection(term()) :: {:ok, SSOConnection.t()} | {:error, :not_found}
  def get_enabled_saml_connection(organization_id) when is_integer(organization_id) do
    case Repo.get_by(SSOConnection,
           organization_id: organization_id,
           protocol: :saml,
           enabled: true
         ) do
      %SSOConnection{} = connection -> {:ok, connection}
      nil -> {:error, :not_found}
    end
  end

  def get_enabled_saml_connection(_organization_id), do: {:error, :not_found}

  @doc "True when the user has signed in through single sign-on at least once."
  @spec user_has_identity?(User.t()) :: boolean()
  def user_has_identity?(%User{id: user_id}) do
    from(i in UserIdentity, where: i.user_id == ^user_id) |> Repo.exists?()
  end

  # --- sign-in -----------------------------------------------------------------

  defdelegate begin_oidc_login(domain, redirect_uri), to: OIDCLogin, as: :begin
  defdelegate complete_oidc_login(flow, params, opts), to: OIDCLogin, as: :complete
  defdelegate begin_saml_login(domain, return_to), to: SAMLLogin, as: :begin
  defdelegate complete_saml_login(organization_id, params, opts), to: SAMLLogin, as: :complete
  defdelegate complete_two_factor_link(user, link, opts), to: TwoFactorLink, as: :complete
end
