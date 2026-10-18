defmodule Kanban.Organizations.OrgAdminProvisioning do
  @moduledoc """
  Creates the account for an org-admin appointed by an email that has none,
  for `Kanban.Organizations.appoint_org_admin_by_email/4`.

  `Kanban.Organizations` checks who is acting and looks the email up; nothing
  else should call this module, because it checks no actor itself.

  The user is registered through `Kanban.Accounts.register_user/1`, so
  `User.registration_changeset/3` validates the email and the password, and
  the org-admin membership is written through
  `Kanban.Organizations.MembershipWrites.appoint_org_admin/4`, all in one
  transaction. If any step fails the user row rolls back with it.

  The password is 32 bytes from `:crypto.strong_rand_bytes/1`, encoded as 43
  URL-safe characters. A valid registration changeset hashes it and drops it,
  and an invalid one has it removed before the changeset is returned, so it is
  never returned, logged, emailed or stored anywhere but the password hash.
  The account is not confirmed. Once the transaction has committed, two emails
  go out: a confirmation email and a choose-your-password email, the org-admin
  versions of the usual confirmation and password-reset emails. They use the
  same tokens but name the Organization and say a site admin created the
  account, so the appointee knows why they were sent and confirms their
  address and chooses their own password.

  Telemetry is held with `Kanban.Telemetry.AfterCommit.after_commit/1`, so the
  registration, `member_added` and `:org_admin_appointed` events are emitted
  only after the commit, and a rolled-back provisioning emits, records and
  sends nothing.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit

  @password_bytes 32

  @typedoc """
  The URL functions for the two login emails. Each takes the encoded token and
  returns the link to put in the email.
  """
  @type urls :: [
          confirmation_url: (String.t() -> String.t()),
          reset_password_url: (String.t() -> String.t())
        ]

  @doc """
  Registers a user with `email` and a random password, makes them an org-admin
  of the Organization with `organization_id`, and once that has committed
  sends them the confirmation and password-reset emails. `actor` has already
  been checked and `email` already trimmed.

  Returns `{:error, :email_taken}` when another write registered `email`
  after the caller looked it up, so the caller can appoint that account
  instead. Any other failure returns its error and leaves nothing behind.
  """
  @spec provision(User.t(), integer(), String.t(), urls()) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :email_taken
             | :already_in_another_organization
             | :not_found
             | Ecto.Changeset.t()}
  def provision(%User{} = actor, organization_id, email, urls) when is_binary(email) do
    fn ->
      Repo.transact(fn ->
        with {:ok, user} <- Accounts.register_user(%{email: email, password: random_password()}),
             {:ok, membership} <-
               MembershipWrites.appoint_org_admin(actor, organization_id, user,
                 account_created: true
               ) do
          {:ok, {user, membership}}
        end
      end)
    end
    |> AfterCommit.after_commit()
    |> after_provisioning(urls)
  end

  @doc """
  Returns `urls` when it holds both URL functions, and raises
  `ArgumentError` otherwise.
  """
  @spec validate_urls!(term()) :: urls()
  def validate_urls!(urls) when is_list(urls) do
    for key <- [:confirmation_url, :reset_password_url] do
      unless is_function(Keyword.get(urls, key), 1) do
        raise ArgumentError, "expected #{inspect(key)} to be a function of arity 1"
      end
    end

    urls
  end

  def validate_urls!(_urls) do
    raise ArgumentError,
          "expected a keyword list with :confirmation_url and :reset_password_url"
  end

  defp after_provisioning({:ok, {user, membership}}, urls) do
    name = organization_name(membership.organization_id)
    Accounts.deliver_org_admin_confirmation_instructions(user, name, urls[:confirmation_url])
    Accounts.deliver_org_admin_password_instructions(user, name, urls[:reset_password_url])
    {:ok, membership}
  end

  defp after_provisioning({:error, %Ecto.Changeset{} = changeset}, _urls) do
    if email_taken?(changeset),
      do: {:error, :email_taken},
      else: {:error, without_password(changeset)}
  end

  defp after_provisioning({:error, _reason} = error, _urls), do: error

  # The caller found no account for the email, but one exists now: either the
  # pre-insert check saw it, or the unique index refused the insert.
  defp email_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:email, {_message, opts}} ->
        opts[:validation] == :unsafe_unique or opts[:constraint] == :unique

      _error ->
        false
    end)
  end

  # `User.registration_changeset/3` hashes and drops the password only when the
  # changeset is valid, so an invalid one still holds the generated password in
  # its changes and params. It is removed before the changeset leaves here.
  defp without_password(%Ecto.Changeset{} = changeset) do
    %{
      changeset
      | changes: Map.delete(changeset.changes, :password),
        params: Map.delete(changeset.params || %{}, "password")
    }
  end

  defp organization_name(organization_id) do
    from(o in Organization, where: o.id == ^organization_id, select: o.name)
    |> Repo.one!()
  end

  defp random_password do
    @password_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
