defmodule Kanban.SSO.Provisioning do
  @moduledoc """
  Just-in-time accounts and Organization membership for single sign-on.

  Shared by every sign-in protocol (OIDC, and SAML since W2246), so it takes a
  connection and the identity provider's claims, already validated, and
  decides who signs in (SCIM provisioning, W2247, has its own entry point,
  `provision_scim/2`, with the same domain and membership rules):

    1. **Known identity.** An identity row for the connection, its issuer and
       the `sub` claim decides the account; the email claim is ignored, so an
       identity provider changing someone's email never moves them to another
       account, and the stored email is never updated from a claim. A
       disabled account is refused. If the account is no longer a member of
       the connection's Organization (it was removed), it is added back as a
       member only when the identity provider asserts `email_verified` and
       the account's own email (not the claim's) is on a domain the
       Organization verified, so offboarding is the identity provider's job,
       and an account moved to an address off those domains is no longer the
       identity provider's to sign in as. A membership SCIM ended is refused
       with `:scim_deprovisioned` until SCIM re-activates it.
    2. **Email gate.** Otherwise the identity provider must assert
       `email_verified`, and the email's domain must be verified by the
       connection's Organization. An account is never linked by email alone.
    3. **New account.** No account has that email: a confirmed account with
       no password is created (with its personal workspace), plus a `:member`
       membership and the identity, in one transaction.
    4. **Existing account.** An enabled account with that email gains a
       `:member` membership if it has none (an org-admin keeps their role) and
       the identity, unless SCIM deprovisioned it (`:scim_deprovisioned`). An account whose email was never confirmed is first
       confirmed, its password removed and its tokens deleted, because
       whoever registered it may not own the address. An account with
       two-factor turned on is not linked yet: `provision/2` returns
       `{:two_factor_required, user}` and writes nothing, and the caller asks
       for a code from the account's authenticator app (or a recovery code)
       before `link_after_two_factor/3` links it. Signing in through the
       identity provider is then enough, so the code is asked for once, before
       the first link (decided 2026-10-21): otherwise the identity provider
       would sign in as an account protected by a second factor it never saw.

  A user who belongs to another Organization is refused with
  `:membership_conflict`, and nothing is written: Organizations never move a
  user. Nothing here reveals which Organization that is.

  A site admin (`type: :admin`) is refused with `:site_admin` on every path,
  known identity or not, and by SCIM too: an Organization's identity provider
  never signs anyone in with site-admin powers. Site admins sign in with their
  password (decided 2026-10-21).

  Records `:sso_user_provisioned` or `:sso_account_linked` once the
  transaction commits. Refusals are audited by the caller
  (`Kanban.SSO.OIDCLogin`, `Kanban.SSO.SAMLLogin`,
  `Kanban.SSO.TwoFactorLink`), which knows the request context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.SCIM.UserLink
  alias Kanban.SSO
  alias Kanban.SSO.DomainVerification
  alias Kanban.SSO.SSOConnection
  alias Kanban.SSO.UserIdentity
  alias Kanban.Telemetry.AfterCommit

  # The longest subject an identity row stores (Kanban.SSO.UserIdentity).
  @max_subject 1024

  @type outcome :: :existing_identity | :linked | :provisioned
  @type refusal ::
          :invalid_claims
          | :email_not_verified
          | :domain_not_verified
          | :user_disabled
          | :membership_conflict
          | :scim_deprovisioned
          | :site_admin

  @doc """
  Decides the account for a sign-in through `connection` with the validated
  id_token `claims`. Returns `{:ok, user, outcome}`, `{:error, refusal}`, or
  `{:two_factor_required, user}` when the sign-in would link an existing
  account that has two-factor turned on (nothing is written; see
  `link_after_two_factor/3`).
  """
  @spec provision(SSOConnection.t(), map()) ::
          {:ok, User.t(), outcome()} | {:error, refusal()} | {:two_factor_required, User.t()}
  def provision(%SSOConnection{} = connection, %{"sub" => subject} = claims)
      when is_binary(subject) and subject != "" and byte_size(subject) <= @max_subject do
    connection |> find_identity(subject) |> provision_for(connection, subject, claims)
  end

  def provision(%SSOConnection{}, _missing_or_oversized), do: {:error, :invalid_claims}

  @doc """
  Links the account with `user_id` to the identity `subject` of `connection`
  once the person has passed that account's two-factor challenge, after
  `provision/2` returned `{:two_factor_required, user}`. The account is read
  again, so one disabled, made a site admin or moved to an email off the
  Organization's verified domains in the meantime is refused, and the link
  itself has the same rules as any other (`:scim_deprovisioned`,
  `:membership_conflict`; an identity linked in the meantime is
  `:invalid_claims`). Returns `{:ok, user, :linked}` or `{:error, refusal}`.
  """
  @spec link_after_two_factor(SSOConnection.t(), String.t(), integer()) ::
          {:ok, User.t(), :linked} | {:error, refusal()}
  def link_after_two_factor(%SSOConnection{} = connection, subject, user_id)
      when is_binary(subject) and subject != "" and is_integer(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :invalid_claims}
      %User{disabled_at: %DateTime{}} -> {:error, :user_disabled}
      %User{type: :admin} -> {:error, :site_admin}
      %User{} = user -> link_verified(connection, subject, user)
    end
  end

  def link_after_two_factor(%SSOConnection{}, _subject, _user_id), do: {:error, :invalid_claims}

  defp link_verified(connection, subject, user) do
    with {:ok, _email} <-
           user.email |> normalized_email() |> on_verified_domain(connection.organization_id) do
      link_existing(connection, subject, user)
    end
  end

  defp find_identity(connection, subject) do
    from(i in UserIdentity,
      where:
        i.sso_connection_id == ^connection.id and i.issuer == ^connection.issuer and
          i.subject == ^subject,
      preload: :user
    )
    |> Repo.one()
  end

  @doc """
  Provisions the account a SCIM client asks for (W2247) in the Organization
  with `organization_id`, from the already-mapped `%{email: ..., name: ...}`
  of the User resource.

  SCIM is the identity provider's own provisioning channel, so there is no
  `email_verified` claim and no identity row; the domain gate is the same as
  for single sign-on: the email's domain must be verified by the
  Organization. Then:

    * no account has that email: a confirmed, passwordless account is
      created (with its personal workspace), marked as managed by the
      Organization, with a `:member` membership, in one transaction
      (`:provisioned`);
    * an enabled account has it: it gains a `:member` membership if it has
      none (an org-admin keeps their role), and an unconfirmed one is
      secured as for single sign-on (`:linked`). A linked account is not
      managed by the Organization, so deprovisioning never disables it.

  A disabled account is refused with `:user_disabled`, a site admin with
  `:site_admin`, a user in another Organization with `:membership_conflict`,
  and nothing is written. Audit
  events are recorded by the SCIM layer, which knows the token.
  """
  @spec provision_scim(integer(), %{email: String.t(), name: String.t() | nil}) ::
          {:ok, User.t(), :provisioned | :linked}
          | {:error,
             :domain_not_verified
             | :user_disabled
             | :site_admin
             | :membership_conflict
             | :invalid_claims}
  def provision_scim(organization_id, %{email: email} = attrs) when is_integer(organization_id) do
    with {:ok, email} <- email |> normalized_email() |> on_verified_domain(organization_id) do
      email
      |> Accounts.get_user_by_email()
      |> provision_scim_user(organization_id, %{email: email, name: attrs[:name]})
    end
  end

  defp provision_scim_user(nil, organization_id, attrs), do: scim_new(organization_id, attrs)

  defp provision_scim_user(%User{disabled_at: %DateTime{}}, _organization_id, _attrs),
    do: {:error, :user_disabled}

  defp provision_scim_user(%User{type: :admin}, _organization_id, _attrs),
    do: {:error, :site_admin}

  defp provision_scim_user(%User{} = user, organization_id, _attrs),
    do: scim_link(organization_id, user)

  defp scim_new(organization_id, attrs) do
    fn -> Repo.transact(fn -> register_managed(organization_id, attrs) end) end
    |> AfterCommit.after_commit()
    |> case do
      {:ok, user} -> {:ok, user, :provisioned}
      # Another request registered the email first: link that account.
      {:error, %Ecto.Changeset{}} -> scim_retry_as_existing(organization_id, attrs.email)
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_managed(organization_id, attrs) do
    with {:ok, user} <- Accounts.register_sso_user(attrs),
         {:ok, user} <- user |> User.managed_by_changeset(organization_id) |> Repo.update(),
         {:ok, _membership} <- add_member(organization_id, user) do
      {:ok, user}
    end
  end

  defp scim_retry_as_existing(organization_id, email) do
    case Accounts.get_user_by_email(email) do
      %User{disabled_at: %DateTime{}} -> {:error, :user_disabled}
      %User{type: :admin} -> {:error, :site_admin}
      %User{} = user -> scim_link(organization_id, user)
      nil -> {:error, :invalid_claims}
    end
  end

  defp scim_link(organization_id, %User{} = user) do
    fn ->
      Repo.transact(fn ->
        with {:ok, _membership} <- add_member(organization_id, user) do
          Accounts.secure_linked_unconfirmed_user(user)
        end
      end)
    end
    |> AfterCommit.after_commit()
    |> case do
      {:ok, user} -> {:ok, user, :linked}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_claims}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- a known identity --------------------------------------------------------

  defp provision_for(%UserIdentity{user: %User{disabled_at: %DateTime{}}}, _conn, _sub, _claims),
    do: {:error, :user_disabled}

  # Also for an identity linked before the account became a site admin.
  defp provision_for(%UserIdentity{user: %User{type: :admin}}, _conn, _sub, _claims),
    do: {:error, :site_admin}

  defp provision_for(%UserIdentity{user: user} = identity, connection, _subject, claims) do
    if Organizations.member?(user, connection.organization_id) do
      touch(identity)
      {:ok, user, :existing_identity}
    else
      rejoin(identity, connection, claims)
    end
  end

  # --- a new identity ----------------------------------------------------------

  defp provision_for(nil, connection, subject, claims) do
    with {:ok, email} <- email_gate(connection, claims) do
      case Accounts.get_user_by_email(email) do
        nil -> provision_new(connection, subject, email, claims)
        %User{disabled_at: %DateTime{}} -> {:error, :user_disabled}
        %User{type: :admin} -> {:error, :site_admin}
        %User{} = user -> link_or_challenge(connection, subject, user)
      end
    end
  end

  # The gate reads the account's own email, not the claim's: someone who left
  # and moved their account to an address off the Organization's domains is
  # no longer the identity provider's to sign in as.
  defp rejoin(identity, connection, claims) do
    with :ok <- email_verified(claims["email_verified"]),
         {:ok, _email} <-
           identity.user.email
           |> normalized_email()
           |> on_verified_domain(connection.organization_id),
         :ok <- not_scim_deprovisioned(connection.organization_id, identity.user),
         {:ok, _membership} <- add_member(connection.organization_id, identity.user) do
      touch(identity)
      {:ok, identity.user, :existing_identity}
    end
  end

  defp provision_new(connection, subject, email, claims) do
    attrs = %{email: email, name: name_claim(claims)}

    connection
    |> create_member_with_identity(subject, attrs)
    |> provisioned(connection, subject, email)
  end

  defp create_member_with_identity(connection, subject, attrs) do
    AfterCommit.after_commit(fn ->
      Repo.transact(fn ->
        with {:ok, user} <- Accounts.register_sso_user(attrs),
             {:ok, _membership} <- add_member(connection.organization_id, user),
             {:ok, _identity} <- insert_identity(user, connection, subject) do
          {:ok, user}
        end
      end)
    end)
  end

  defp provisioned({:ok, user}, connection, _subject, _email) do
    AuditLog.event(:sso_user_provisioned, audit_metadata(user, connection))
    {:ok, user, :provisioned}
  end

  # Another request registered the email first: link that account.
  defp provisioned({:error, %Ecto.Changeset{}}, connection, subject, email),
    do: retry_as_existing(connection, subject, email)

  defp provisioned({:error, reason}, _connection, _subject, _email), do: {:error, reason}

  defp retry_as_existing(connection, subject, email) do
    case Accounts.get_user_by_email(email) do
      %User{disabled_at: %DateTime{}} -> {:error, :user_disabled}
      %User{type: :admin} -> {:error, :site_admin}
      %User{} = user -> link_or_challenge(connection, subject, user)
      nil -> {:error, :invalid_claims}
    end
  end

  # A deprovisioned account is refused before any challenge, so the person is
  # not asked for a code only to be turned away.
  defp link_or_challenge(connection, subject, user) do
    cond do
      not_scim_deprovisioned(connection.organization_id, user) != :ok ->
        {:error, :scim_deprovisioned}

      Accounts.two_factor_enabled?(user) ->
        {:two_factor_required, user}

      true ->
        link_existing(connection, subject, user)
    end
  end

  defp link_existing(connection, subject, %User{} = user) do
    with :ok <- not_scim_deprovisioned(connection.organization_id, user) do
      connection
      |> add_member_with_identity(subject, user)
      |> linked(connection)
    end
  end

  defp add_member_with_identity(connection, subject, user) do
    AfterCommit.after_commit(fn ->
      Repo.transact(fn ->
        with {:ok, _membership} <- add_member(connection.organization_id, user),
             {:ok, user} <- Accounts.secure_linked_unconfirmed_user(user),
             {:ok, _identity} <- insert_identity(user, connection, subject) do
          {:ok, user}
        end
      end)
    end)
  end

  defp linked({:ok, user}, connection) do
    AuditLog.event(:sso_account_linked, audit_metadata(user, connection))
    {:ok, user, :linked}
  end

  defp linked({:error, %Ecto.Changeset{}}, _connection), do: {:error, :invalid_claims}
  defp linked({:error, reason}, _connection), do: {:error, reason}

  # --- helpers -----------------------------------------------------------------

  defp email_gate(connection, claims) do
    with :ok <- email_verified(claims["email_verified"]) do
      claims["email"]
      |> normalized_email()
      |> on_verified_domain(connection.organization_id)
    end
  end

  defp on_verified_domain(email, organization_id) when is_binary(email) do
    with {:ok, domain} <- DomainVerification.email_domain(email),
         true <- SSO.domain_verified_by?(organization_id, domain) do
      {:ok, email}
    else
      _domain -> {:error, :domain_not_verified}
    end
  end

  defp on_verified_domain(nil, _organization_id), do: {:error, :domain_not_verified}

  # Some providers (such as Amazon Cognito) send the boolean as a string.
  defp email_verified(true), do: :ok
  defp email_verified("true"), do: :ok
  defp email_verified(_other), do: {:error, :email_not_verified}

  # Lowercased so a new account matches the citext lookup's spelling, and
  # without the trailing dots the domain gate ignores, so `boss@example.com.`
  # finds `boss@example.com` instead of making a second account; the local
  # part is kept as it is otherwise (plus-addresses are their own mailboxes
  # and are never merged).
  defp normalized_email(email) when is_binary(email) do
    case DomainVerification.normalize_email(email) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_email(_email), do: nil

  defp name_claim(%{"name" => name}) when is_binary(name), do: String.slice(name, 0, 160)
  defp name_claim(_claims), do: nil

  # SCIM ended this membership, so only SCIM re-activates it: an identity
  # provider that still lets the person sign in never undoes its own
  # deprovisioning.
  defp not_scim_deprovisioned(organization_id, %User{id: user_id}) do
    case UserLink.get(organization_id, user_id) do
      %UserLink{deprovisioned_at: %DateTime{}} -> {:error, :scim_deprovisioned}
      _link -> :ok
    end
  end

  defp add_member(organization_id, user) do
    case Organizations.add_member(organization_id, user, :member) do
      {:ok, membership} -> {:ok, membership}
      {:error, :already_in_another_organization} -> {:error, :membership_conflict}
      {:error, :user_disabled} -> {:error, :user_disabled}
      {:error, _other} -> {:error, :invalid_claims}
    end
  end

  defp insert_identity(user, connection, subject) do
    user |> UserIdentity.new_changeset(connection, subject) |> Repo.insert()
  end

  defp touch(%UserIdentity{} = identity) do
    identity
    |> Ecto.Changeset.change(last_login_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  # The audit calls name their action literally so the telemetry source scan
  # (test/kanban/telemetry/emit_sites_test.exs) finds them.
  defp audit_metadata(user, connection) do
    [
      user_id: user.id,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id
    ]
  end
end
