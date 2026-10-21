defmodule Kanban.SCIM.Users do
  @moduledoc """
  The SCIM `/Users` resource of an Organization (W2247).

  A token reaches only the users of its own Organization: its members, and
  the users whose membership SCIM itself ended (who have a
  `Kanban.SCIM.UserLink` marked deprovisioned and no membership anywhere). A
  user in another Organization, a former member the Organization removed some
  other way, or any other account, is not found, whatever the id or filter,
  so a token can never read or change them.

  `get/2` and `create/2` return a record `%{user: user, active: active,
  member: member, link: link}` for the web layer to render, `replace/3` and
  `patch/3` return one with the sessions to disconnect, and `list/2` returns
  a page of them; `delete/2` returns only the sessions. `member` is true when
  the user is a member of the Organization, and `active` when they are a
  member and the account is enabled.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM.Filter
  alias Kanban.SCIM.Lifecycle
  alias Kanban.SCIM.ListParams
  alias Kanban.SCIM.Patch
  alias Kanban.SCIM.ScimToken
  alias Kanban.SCIM.UserLink
  alias Kanban.SCIM.UserMapping
  alias Kanban.SSO.Provisioning

  @max_bigint 9_223_372_036_854_775_807

  @type resource_record :: %{
          user: User.t(),
          active: boolean(),
          member: boolean(),
          link: UserLink.t() | nil
        }
  @type error ::
          :not_found
          | :invalid_filter
          | :invalid_syntax
          | :invalid_value
          | :mutability
          | :uniqueness
          | :domain_not_verified
          | :inactive_create
          | :user_disabled
          | :membership_conflict
          | :last_org_admin

  @doc """
  Lists the Organization's users a page at a time, optionally filtered by
  `userName eq "..."` (compared case-insensitively). Returns
  `{:ok, %{total: total, start_index: start_index, records: records}}`.
  """
  @spec list(ScimToken.t(), map()) ::
          {:ok,
           %{total: non_neg_integer(), start_index: pos_integer(), records: [resource_record()]}}
          | {:error, :invalid_filter}
  def list(%ScimToken{organization_id: organization_id}, params) when is_map(params) do
    page = ListParams.parse(params)

    with {:ok, query} <- filtered(visible_query(organization_id), params["filter"]) do
      {:ok,
       %{
         total: Repo.aggregate(query, :count),
         start_index: page.start_index,
         records: page_records(query, page, organization_id)
       }}
    end
  end

  defp page_records(query, page, organization_id) do
    query
    |> order_by([u], asc: u.id)
    |> offset(^(page.start_index - 1))
    |> limit(^page.count)
    |> select([u, m, l], {u, m, l})
    |> Repo.all()
    |> Enum.map(&to_record(&1, organization_id))
  end

  defp filtered(query, filter) do
    case Filter.parse(filter, ["userName"]) do
      :none -> {:ok, query}
      {:ok, {"userName", value}} -> {:ok, where(query, [u], u.email == ^value)}
      {:error, :invalid_filter} = error -> error
    end
  end

  @doc "The Organization's user with `id`, or `{:error, :not_found}`."
  @spec get(ScimToken.t(), term()) :: {:ok, resource_record()} | {:error, :not_found}
  def get(%ScimToken{organization_id: organization_id}, id) do
    case parse_id(id) do
      nil -> {:error, :not_found}
      user_id -> fetch(organization_id, user_id)
    end
  end

  defp fetch(organization_id, user_id) do
    organization_id
    |> visible_query()
    |> where([u], u.id == ^user_id)
    |> select([u, m, l], {u, m, l})
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      row -> {:ok, to_record(row, organization_id)}
    end
  end

  # Members of the Organization, and users SCIM deprovisioned from it who
  # have no membership at all.
  defp visible_query(organization_id) do
    from(u in User,
      left_join: m in OrganizationMember,
      on: m.user_id == u.id,
      left_join: l in UserLink,
      on: l.user_id == u.id and l.organization_id == ^organization_id,
      where:
        m.organization_id == ^organization_id or
          (not is_nil(l.deprovisioned_at) and is_nil(m.id))
    )
  end

  defp to_record({user, membership, link}, organization_id) do
    member = member_of?(membership, organization_id)
    %{user: user, active: is_nil(user.disabled_at) and member, member: member, link: link}
  end

  defp member_of?(%OrganizationMember{organization_id: id}, organization_id),
    do: id == organization_id

  defp member_of?(nil, _organization_id), do: false

  @doc """
  Provisions the user a POST asks for (`Kanban.SSO.Provisioning.provision_scim/2`)
  and links them to the Organization. A deprovisioned account the
  Organization manages is re-activated instead, including one a DELETE
  removed. Returns `{:ok, record}`, `{:error, :uniqueness}` when the user is
  already a member, or `{:error, :inactive_create}` when the body sets
  `active` to false.
  """
  @spec create(ScimToken.t(), term()) :: {:ok, resource_record()} | {:error, error()}
  def create(%ScimToken{} = token, body) do
    with {:ok, attributes} <- UserMapping.from_resource(body),
         :ok <- check_active(attributes),
         {:ok, user} <- provision(token, attributes) do
      link_provisioned(token, user, attributes)
    end
  end

  defp link_provisioned(%ScimToken{organization_id: org_id} = token, user, attributes) do
    with {:ok, _link} <- UserLink.upsert(org_id, user.id, attributes.external_id) do
      parts = Map.take(attributes, [:given_name, :family_name])
      _fields = update_name_parts(token, user, nil, {:ok, parts})
      fetch(org_id, user.id)
    end
  end

  defp check_active(%{active: true}), do: :ok
  defp check_active(%{active: false}), do: {:error, :inactive_create}

  defp provision(token, %{email: email} = attributes) do
    case Accounts.get_user_by_email(email) do
      %User{} = user -> provision_existing(token, user, attributes)
      nil -> provision_new(token, attributes)
    end
  end

  # An account the Organization manages that is no longer found was removed
  # by a DELETE: provisioning it again re-activates it.
  defp provision_existing(token, user, attributes) do
    case fetch(token.organization_id, user.id) do
      {:ok, %{active: true}} -> {:error, :uniqueness}
      {:ok, %{active: false}} -> Lifecycle.reactivate(token, user)
      {:error, :not_found} -> provision_unlisted(token, user, attributes)
    end
  end

  defp provision_unlisted(
         %ScimToken{organization_id: org_id} = token,
         %User{managed_by_organization_id: org_id} = user,
         _attributes
       ),
       do: Lifecycle.reactivate(token, user)

  defp provision_unlisted(token, _user, attributes), do: provision_new(token, attributes)

  defp provision_new(token, attributes) do
    case Provisioning.provision_scim(token.organization_id, attributes) do
      {:ok, user, outcome} ->
        AuditLog.event(:scim_user_provisioned,
          organization_id: token.organization_id,
          scim_token_id: token.id,
          member_user_id: user.id,
          outcome: provisioned_outcome(outcome)
        )

        {:ok, user}

      {:error, :invalid_claims} ->
        {:error, :invalid_value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provisioned_outcome(:provisioned), do: :created
  defp provisioned_outcome(:linked), do: :linked

  @doc """
  Replaces the user's attributes from a PUT body. `userName` cannot change;
  `active` drives deprovisioning and re-activation. Returns `{:ok, record,
  sessions}` where `sessions` is what `Kanban.SCIM.Lifecycle` returned, or
  `:none`.
  """
  @spec replace(ScimToken.t(), term(), term()) ::
          {:ok, resource_record(), Lifecycle.sessions() | :none} | {:error, error()}
  def replace(%ScimToken{} = token, id, body) do
    with {:ok, record} <- get(token, id),
         {:ok, attributes} <- UserMapping.from_resource(body) do
      apply_changes(token, record, replace_changes(attributes, body))
    end
  end

  # A PUT that leaves out active or externalId changes neither.
  defp replace_changes(attributes, body) do
    attributes
    |> Map.take([:name, :external_id, :active])
    |> Map.put(:user_name, body["userName"])
    |> put_replaced_name_parts(attributes)
    |> Map.reject(fn {key, value} -> key == :name and is_nil(value) end)
    |> drop_unless_sent(body, "active", :active)
    |> drop_unless_sent(body, "externalId", :external_id)
  end

  # A PUT replaces the name parts along with the name, and leaves both when
  # it sends no name.
  defp put_replaced_name_parts(changes, %{name: nil}), do: changes

  defp put_replaced_name_parts(changes, attributes),
    do: Map.put(changes, :name_parts, Map.take(attributes, [:given_name, :family_name]))

  defp drop_unless_sent(changes, body, attribute, key) do
    if Map.has_key?(body, attribute), do: changes, else: Map.delete(changes, key)
  end

  @doc """
  Applies a PATCH body's operations to the user. Returns as `replace/3`.
  """
  @spec patch(ScimToken.t(), term(), term()) ::
          {:ok, resource_record(), Lifecycle.sessions() | :none} | {:error, error()}
  def patch(%ScimToken{} = token, id, body) do
    with {:ok, record} <- get(token, id),
         {:ok, changes} <- Patch.user_changes(body) do
      apply_changes(token, record, merge_name_parts(changes, record))
    end
  end

  # A PATCH of one name part keeps the other (RFC 7644 §3.5.2.3): the parts
  # sent are merged into the stored ones, and the name is made up from them
  # unless a formatted name was sent.
  defp merge_name_parts(%{name_parts: sent} = changes, %{user: user, link: link}) do
    stored = UserMapping.name_parts(user, link)

    parts = %{
      given_name: sent_or_stored(sent, :given, stored.given),
      family_name: sent_or_stored(sent, :family, stored.family)
    }

    changes = Map.put(changes, :name_parts, parts)

    if Map.has_key?(sent, :formatted) or not parts_sent?(sent),
      do: changes,
      else:
        put_name(changes, UserMapping.name(%{given: parts.given_name, family: parts.family_name}))
  end

  defp merge_name_parts(changes, _record), do: changes

  defp sent_or_stored(sent, key, stored) do
    if Map.has_key?(sent, key), do: UserMapping.name_part(sent[key]), else: stored
  end

  defp parts_sent?(sent), do: Map.has_key?(sent, :given) or Map.has_key?(sent, :family)

  defp put_name(changes, nil), do: Map.delete(changes, :name)
  defp put_name(changes, name), do: Map.put(changes, :name, name)

  # Everything that can refuse runs before anything is written: the userName
  # and name checks, then the active change, which can be refused (the last
  # org-admin, a disabled account). Only then are the name and externalId
  # written, so a refused request changes nothing.
  defp apply_changes(token, %{user: user} = record, changes) do
    with :ok <- check_user_name(changes, user),
         {:ok, name_change} <- name_changeset(token, user, Map.fetch(changes, :name)),
         {:ok, sessions} <- change_active(token, record, Map.fetch(changes, :active)) do
      fields = write_changes(token, record, name_change, changes)
      finish_update(token, user, fields, sessions)
    end
  end

  defp finish_update(token, user, fields, sessions) do
    {:ok, updated} = fetch(token.organization_id, user.id)
    audit_update(token, user, fields)
    {:ok, updated, sessions}
  end

  defp write_changes(token, %{user: user, link: link}, name_change, changes) do
    parts = update_name_parts(token, user, link, Map.fetch(changes, :name_parts))
    external_id = update_external_id(token, user, link, Map.fetch(changes, :external_id))
    Enum.uniq(update_name(name_change) ++ parts ++ external_id)
  end

  defp check_user_name(%{user_name: user_name}, user) when is_binary(user_name) do
    if UserMapping.same_user_name?(user_name, user), do: :ok, else: {:error, :mutability}
  end

  defp check_user_name(_changes, _user), do: :ok

  # Only an account the Organization manages takes its name from the
  # identity provider; anyone else's name is theirs to keep. Returns the
  # validated changeset to write, or nil when there is nothing to change.
  defp name_changeset(
         %ScimToken{organization_id: org_id},
         %User{managed_by_organization_id: org_id} = user,
         {:ok, name}
       )
       when is_binary(name) and name != user.name do
    case User.name_changeset(user, %{name: name}) do
      %Ecto.Changeset{valid?: true} = changeset -> {:ok, changeset}
      %Ecto.Changeset{} -> {:error, :invalid_value}
    end
  end

  defp name_changeset(_token, _user, _change), do: {:ok, nil}

  defp update_name(nil), do: []

  defp update_name(%Ecto.Changeset{} = changeset) do
    {:ok, _user} = Repo.update(changeset)
    [:name]
  end

  # The parts are kept only for an account the Organization manages, whose
  # name it sets.
  defp update_name_parts(
         %ScimToken{organization_id: org_id},
         %User{managed_by_organization_id: org_id} = user,
         link,
         {:ok, %{given_name: given, family_name: family}}
       ) do
    if is_nil(link) or link.given_name != given or link.family_name != family do
      {:ok, _link} = UserLink.upsert(org_id, user.id, :keep)
      :ok = UserLink.put_name_parts(org_id, user.id, given, family)
      [:name]
    else
      []
    end
  end

  defp update_name_parts(_token, _user, _link, _change), do: []

  defp update_external_id(token, user, link, {:ok, external_id}) do
    if is_nil(link) or link.external_id != external_id do
      {:ok, _link} = UserLink.upsert(token.organization_id, user.id, external_id)
      [:external_id]
    else
      []
    end
  end

  defp update_external_id(_token, _user, _link, :error), do: []

  # A member is deprovisioned on active false even when their account is
  # already disabled, so the Organization's access never outlives the
  # identity provider's removal.
  defp change_active(token, %{user: user} = record, {:ok, false})
       when record.active or record.member,
       do: Lifecycle.deprovision(token, user, :deactivated)

  defp change_active(token, %{user: user, active: false}, {:ok, true}) do
    with {:ok, _user} <- Lifecycle.reactivate(token, user), do: {:ok, :none}
  end

  defp change_active(_token, _record, _change), do: {:ok, :none}

  defp audit_update(_token, _user, []), do: :ok

  defp audit_update(token, user, fields) do
    AuditLog.event(:scim_user_updated,
      organization_id: token.organization_id,
      scim_token_id: token.id,
      member_user_id: user.id,
      fields: fields
    )
  end

  @doc """
  Deprovisions the user and detaches their link, so they are no longer found
  and their `externalId` and name parts are forgotten. The link is kept so a
  later POST can re-enable an account SCIM disabled.
  Returns `{:ok, sessions}`.
  """
  @spec delete(ScimToken.t(), term()) ::
          {:ok, Lifecycle.sessions()} | {:error, :not_found | :last_org_admin}
  def delete(%ScimToken{} = token, id) do
    with {:ok, %{user: user}} <- get(token, id) do
      Lifecycle.deprovision(token, user, :deleted)
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
