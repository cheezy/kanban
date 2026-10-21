defmodule Kanban.Workspaces.Export.Importer.Users do
  @moduledoc """
  Matches an archive's users to accounts on this instance, for
  `Kanban.Workspaces.Export.Importer` (W2222).

  A user is matched by email to an enabled account and never created. Two
  maps come out of it:

    * `users` — every matched user, for the importer's membership checks,
      which then decide on their own whether each one belongs to the
      Organization;
    * `attributable` — only the matched users who are members of the
      importing Organization. Task, comment and history attributions (who
      created, was assigned, completed, reviewed or archived a task, who wrote
      or is mentioned in a comment, and who a history row names) come from
      this map alone, so an archive can never make imported rows name an
      account outside the Organization. Such attributions are left empty,
      like those of a user with no account here, and each such user is named
      in the report's skipped list.

  An archive user with no match is reported in one of two lists:
  `unmatched_users` when no account here has their email, and
  `disabled_users` when one does but it is disabled.
  `unmatched_reason/2` says which, for the importer's skip lines.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @doc """
  Matches `ctx.rows.users` and puts `:users`, `:attributable`, `:emails`,
  `:unmatched_users`, `:disabled_users` and `:counts` (with the matched user
  count) on `ctx`,
  adding a `:users` skip for each matched user outside
  `ctx.organization_id`.
  """
  @spec match(map()) :: map()
  def match(%{rows: %{users: users}, organization_id: organization_id} = ctx) do
    {user_map, unmatched, matched_count} = match_all(users)
    {attributable, outside} = split_by_organization(user_map, organization_id)
    emails = source_emails(users)

    ctx
    |> Map.merge(%{
      users: user_map,
      attributable: attributable,
      emails: emails,
      counts: %{users: matched_count}
    })
    |> Map.merge(split_unmatched(unmatched))
    |> skip_outside(outside, emails)
  end

  # The unmatched emails, split into those with no account here and those
  # whose account is disabled.
  defp split_unmatched(unmatched) do
    disabled = disabled_emails(unmatched)
    {disabled_users, unmatched} = Enum.split_with(unmatched, &disabled?(&1, disabled))
    %{unmatched_users: sorted_emails(unmatched), disabled_users: sorted_emails(disabled_users)}
  end

  @doc """
  Why the archive's user `source_id` was not matched, naming them:
  "<email> has no account here" or "<email> has a disabled account here".
  """
  @spec unmatched_reason(map(), term()) :: String.t()
  def unmatched_reason(ctx, source_id) do
    case Map.get(ctx.emails, source_id) do
      email when is_binary(email) ->
        if email in ctx.disabled_users,
          do: "#{email} has a disabled account here",
          else: "#{email} has no account here"

      _no_email ->
        "an unknown user has no account here"
    end
  end

  @doc "The local id of the archive's user `source_id`, or nil when unmatched."
  @spec user(map(), term()) :: integer() | nil
  def user(ctx, source_id), do: Map.get(ctx.users, source_id)

  @doc """
  The local id to attribute imported rows to for the archive's user
  `source_id`: nil unless they are matched and in the importing Organization.
  """
  @spec attributed(map(), term()) :: integer() | nil
  def attributed(ctx, source_id), do: Map.get(ctx.attributable, source_id)

  # {source id => local id or nil, unmatched emails, matched account count}
  defp match_all(users) do
    local = local_user_ids(users)
    {user_map, unmatched} = Enum.reduce(users, {%{}, []}, &match_user(&1, &2, local))
    {user_map, unmatched, map_size(local)}
  end

  # Enabled local accounts whose email appears in the archive, keyed by the
  # downcased email.
  defp local_user_ids(users) do
    users
    |> archive_emails()
    |> enabled_users_query()
    |> Repo.all()
    |> Map.new(fn {email, id} -> {String.downcase(email), id} end)
  end

  defp archive_emails(users), do: for(%{"email" => email} <- users, is_binary(email), do: email)

  defp enabled_users_query(emails) do
    from(u in User,
      where: u.email in ^emails and is_nil(u.disabled_at),
      select: {u.email, u.id}
    )
  end

  # Downcased emails, among `emails`, of disabled accounts here.
  defp disabled_emails(emails) do
    emails = Enum.filter(emails, &is_binary/1)

    from(u in User, where: u.email in ^emails and not is_nil(u.disabled_at), select: u.email)
    |> Repo.all()
    |> MapSet.new(&String.downcase/1)
  end

  defp disabled?(email, disabled),
    do: is_binary(email) and MapSet.member?(disabled, String.downcase(email))

  defp match_user(row, {map, unmatched}, local) do
    email = if is_binary(row["email"]), do: String.downcase(row["email"])
    local_id = Map.get(local, email)
    unmatched = if local_id, do: unmatched, else: [row["email"] | unmatched]
    {Map.put(map, row["id"], local_id), unmatched}
  end

  # {members of the Organization, everyone else}, both as source id => local id.
  defp split_by_organization(user_map, organization_id) do
    members = organization_user_ids(organization_id, Map.values(user_map))
    Map.split_with(user_map, &attributable?(&1, members))
  end

  defp organization_user_ids(organization_id, user_ids) do
    from(m in OrganizationMember,
      where:
        m.organization_id == ^organization_id and m.user_id in ^Enum.reject(user_ids, &is_nil/1),
      select: m.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # An unmatched user (nil) is neither attributable nor reported as outside:
  # the report already lists them as having no account here.
  defp attributable?({_source_id, nil}, _members), do: false
  defp attributable?({_source_id, local_id}, members), do: MapSet.member?(members, local_id)

  defp skip_outside(ctx, outside, emails) do
    outside
    |> Enum.reject(fn {_source_id, local_id} -> is_nil(local_id) end)
    |> Enum.map(fn {source_id, _local_id} -> Map.get(emails, source_id) end)
    |> sorted_emails()
    |> Enum.reduce(ctx, fn email, ctx ->
      reason = "#{email} is not in the Organization; their attributions were left empty"
      %{ctx | skipped: [{:users, reason} | ctx.skipped]}
    end)
  end

  defp source_emails(users), do: Map.new(users, &{&1["id"], &1["email"]})

  defp sorted_emails(emails), do: emails |> Enum.reject(&is_nil/1) |> Enum.sort()
end
