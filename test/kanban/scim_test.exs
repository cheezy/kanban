defmodule Kanban.SCIMTest do
  @moduledoc """
  `Kanban.SCIM` (W2247): tokens, the Users resource with deprovisioning and
  re-activation, and Groups as the Organization's workspaces.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [from: 2, where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures
  import Kanban.SSOFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.AuditLog
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM
  alias Kanban.SCIM.ScimToken
  alias Kanban.SCIM.UserLink
  alias Kanban.SCIM.UserMapping
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  setup do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization).domain
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    {token, _plaintext} = scim_token_fixture(organization, %{created_by: org_admin})
    workspace = org_workspace_fixture(organization)

    %{
      organization: organization,
      domain: domain,
      org_admin: org_admin,
      token: token,
      workspace: workspace
    }
  end

  defp email(domain), do: "person#{System.unique_integer([:positive])}@#{domain}"

  defp create!(ctx, attrs \\ %{}) do
    body = Map.merge(%{"userName" => email(ctx.domain), "externalId" => "ext-1"}, attrs)
    {:ok, record} = SCIM.create_user(ctx.token, body)
    record
  end

  defp org_board(workspace) do
    board = board_fixture(user_fixture())

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.get!(Board, board.id)
  end

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp api_token(user, board) do
    {:ok, {token, _plain}} =
      ApiTokens.create_api_token(user, board, %{
        name: "Agent",
        agent_model: "claude",
        agent_version: "v1",
        agent_purpose: "work"
      })

    token
  end

  defp revoked?(token), do: not is_nil(Repo.get!(ApiToken, token.id).revoked_at)

  defp deactivate(ctx, user) do
    SCIM.patch_user(ctx.token, user.id, %{
      "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
    })
  end

  defp reactivate(ctx, user) do
    SCIM.patch_user(ctx.token, user.id, %{
      "Operations" => [%{"op" => "replace", "path" => "active", "value" => "True"}]
    })
  end

  # A member with board access in the Organization, an API token for that
  # board, a personal board with its own token, and a live session.
  defp member_with_access(ctx, user) do
    board = org_board(ctx.workspace)
    workspace_member_fixture(ctx.workspace, user)
    grant(board, user, :modify)
    org_token = api_token(user, board)
    personal_token = api_token(user, board_fixture(user))
    Accounts.generate_user_session_token(user)
    %{board: board, org_token: org_token, personal_token: personal_token}
  end

  describe "tokens" do
    test "an org-admin creates a token shown once and stored hashed", ctx do
      assert {:ok, {token, plaintext}} =
               SCIM.create_token(ctx.org_admin, ctx.organization.id, %{"name" => " Okta "})

      assert "stride_scim_" <> _ = plaintext
      assert is_nil(token.token)
      stored = Repo.get!(ScimToken, token.id)
      assert stored.name == "Okta"
      assert stored.token_hash == ScimToken.hash(plaintext)
      refute stored.token_hash == plaintext

      assert [event] = AuditLog.list_events(action: :scim_token_created)
      assert event.organization_id == ctx.organization.id
      assert event.metadata["scim_token_id"] == token.id
      refute inspect(event.metadata) =~ plaintext
    end

    test "only an enabled org-admin of the Organization can create or revoke", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      for actor <- [member, other_admin, user_fixture()] do
        assert SCIM.create_token(actor, ctx.organization.id, %{"name" => "x"}) ==
                 {:error, :unauthorized}

        assert SCIM.revoke_token(actor, ctx.organization.id, ctx.token.id) ==
                 {:error, :unauthorized}
      end

      {:ok, _} =
        ctx.org_admin |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()

      assert SCIM.create_token(ctx.org_admin, ctx.organization.id, %{"name" => "x"}) ==
               {:error, :unauthorized}
    end

    test "a blank name is refused", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               SCIM.create_token(ctx.org_admin, ctx.organization.id, %{"name" => "  "})

      assert "can't be blank" in errors_on(changeset).name
      assert SCIM.change_token(%{}).valid? == false
    end

    test "revoking is scoped to the Organization and audited", ctx do
      {other_token, _} = scim_token_fixture(organization_fixture())

      assert SCIM.revoke_token(ctx.org_admin, ctx.organization.id, other_token.id) ==
               {:error, :not_found}

      assert SCIM.revoke_token(ctx.org_admin, ctx.organization.id, "nope") == {:error, :not_found}
      assert SCIM.revoke_token(ctx.org_admin, ctx.organization.id, -1) == {:error, :not_found}

      assert {:ok, revoked} =
               SCIM.revoke_token(ctx.org_admin, ctx.organization.id, "#{ctx.token.id}")

      assert revoked.revoked_at
      assert {:ok, ^revoked} = SCIM.revoke_token(ctx.org_admin, ctx.organization.id, ctx.token.id)
      assert [_event] = AuditLog.list_events(action: :scim_token_revoked)
    end

    test "list_tokens/1 lists the Organization's tokens with their creator", ctx do
      scim_token_fixture(organization_fixture())
      assert [token] = SCIM.list_tokens(ctx.organization.id)
      assert token.id == ctx.token.id
      assert token.created_by.id == ctx.org_admin.id
    end

    test "authenticate/1 accepts only an active token and throttles last_used_at", ctx do
      {token, plaintext} = scim_token_fixture(ctx.organization)

      assert {:ok, authenticated} = SCIM.authenticate(plaintext)
      assert authenticated.id == token.id
      first_use = Repo.get!(ScimToken, token.id).last_used_at
      assert first_use

      earlier = DateTime.add(first_use, -30)
      ScimToken |> where([t], t.id == ^token.id) |> Repo.update_all(set: [last_used_at: earlier])
      assert {:ok, _} = SCIM.authenticate(plaintext)
      assert Repo.get!(ScimToken, token.id).last_used_at == earlier

      stale = DateTime.add(first_use, -120)
      ScimToken |> where([t], t.id == ^token.id) |> Repo.update_all(set: [last_used_at: stale])
      assert {:ok, _} = SCIM.authenticate(plaintext)
      assert DateTime.after?(Repo.get!(ScimToken, token.id).last_used_at, stale)

      {:ok, _} = SCIM.revoke_token(ctx.org_admin, ctx.organization.id, token.id)
      assert SCIM.authenticate(plaintext) == {:error, :revoked}
      assert SCIM.authenticate("stride_scim_unknown") == {:error, :not_found}
    end
  end

  describe "creating users" do
    test "provisions a new, managed account with a member membership", ctx do
      address = email(ctx.domain)

      assert {:ok, %{user: user, active: true, link: link}} =
               SCIM.create_user(ctx.token, %{
                 "userName" => String.upcase(address),
                 "name" => %{"givenName" => "Pat", "familyName" => "Person"},
                 "externalId" => "00u1"
               })

      assert user.email == address
      assert user.name == "Pat Person"
      assert user.confirmed_at
      assert user.managed_by_organization_id == ctx.organization.id
      assert link.external_id == "00u1"

      assert %OrganizationMember{role: :member} =
               Repo.get_by(OrganizationMember,
                 user_id: user.id,
                 organization_id: ctx.organization.id
               )

      assert [event] = AuditLog.list_events(action: :scim_user_provisioned)
      assert event.metadata["outcome"] == "created"
      assert event.metadata["scim_token_id"] == ctx.token.id
      assert event.organization_id == ctx.organization.id
    end

    test "links an existing account without managing it", ctx do
      existing = user_fixture(%{email: email(ctx.domain)})

      assert {:ok, %{user: user, active: true}} =
               SCIM.create_user(ctx.token, %{"userName" => existing.email})

      assert user.id == existing.id
      assert is_nil(Repo.reload(existing).managed_by_organization_id)
      assert [event] = AuditLog.list_events(action: :scim_user_provisioned)
      assert event.metadata["outcome"] == "linked"
    end

    test "refuses unverified domains, other Organizations, duplicates and bad bodies", ctx do
      assert SCIM.create_user(ctx.token, %{"userName" => "x@unverified.example"}) ==
               {:error, :domain_not_verified}

      elsewhere = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(organization_fixture(), elsewhere)

      assert SCIM.create_user(ctx.token, %{"userName" => elsewhere.email}) ==
               {:error, :membership_conflict}

      %{user: user} = create!(ctx)
      assert SCIM.create_user(ctx.token, %{"userName" => user.email}) == {:error, :uniqueness}

      assert SCIM.create_user(ctx.token, %{"userName" => email(ctx.domain), "active" => false}) ==
               {:error, :inactive_create}

      assert SCIM.create_user(ctx.token, %{"name" => "x"}) == {:error, :invalid_value}
    end

    test "refuses a disabled account the Organization does not manage", ctx do
      disabled = user_fixture(%{email: email(ctx.domain)})
      {:ok, _} = disabled |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()

      assert SCIM.create_user(ctx.token, %{"userName" => disabled.email}) ==
               {:error, :user_disabled}
    end

    test "re-creating a deprovisioned managed user re-activates it", ctx do
      %{user: user} = create!(ctx)
      {:ok, _record, _sessions} = deactivate(ctx, user)

      assert {:ok, %{user: again, active: true}} =
               SCIM.create_user(ctx.token, %{"userName" => user.email})

      assert again.id == user.id
      assert is_nil(again.disabled_at)
    end
  end

  describe "reading users" do
    test "lists only the Organization's users, paginated", ctx do
      first = create!(ctx).user
      second = create!(ctx).user
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), user_fixture())

      assert {:ok, %{total: 3, start_index: 1, records: records}} =
               SCIM.list_users(ctx.token, %{})

      ids = Enum.map(records, & &1.user.id)
      assert Enum.sort(ids) == Enum.sort([ctx.org_admin.id, first.id, second.id])
      refute outsider.id in ids

      assert {:ok, %{total: 3, start_index: 2, records: [%{user: on_page_two}]}} =
               SCIM.list_users(ctx.token, %{"startIndex" => "2", "count" => "1"})

      assert on_page_two.id == ids |> Enum.sort() |> Enum.at(1)
    end

    test "filters by userName, case-insensitively", ctx do
      %{user: user} = create!(ctx)

      assert {:ok, %{total: 1, records: [%{user: found}]}} =
               SCIM.list_users(ctx.token, %{
                 "filter" => ~s(userName eq "#{String.upcase(user.email)}")
               })

      assert found.id == user.id

      assert {:ok, %{total: 0}} =
               SCIM.list_users(ctx.token, %{"filter" => ~s(userName eq "nobody@example.com")})

      assert SCIM.list_users(ctx.token, %{"filter" => ~s(userName co "a")}) ==
               {:error, :invalid_filter}
    end

    test "never finds a user outside the token's Organization", ctx do
      other = organization_fixture()
      outsider = user_fixture()
      organization_member_fixture(other, outsider)
      {other_token, _} = scim_token_fixture(other)

      assert SCIM.get_user(ctx.token, outsider.id) == {:error, :not_found}
      assert SCIM.get_user(ctx.token, "x") == {:error, :not_found}
      assert SCIM.get_user(other_token, ctx.org_admin.id) == {:error, :not_found}
      assert SCIM.patch_user(ctx.token, outsider.id, %{}) == {:error, :not_found}
      assert SCIM.replace_user(ctx.token, outsider.id, %{}) == {:error, :not_found}
      assert SCIM.delete_user(ctx.token, outsider.id) == {:error, :not_found}
      assert Organizations.member?(outsider, other.id)
    end
  end

  describe "deprovisioning" do
    test "a managed account is disabled, its sessions deleted and every API token revoked",
         ctx do
      %{user: user} = create!(ctx)
      access = member_with_access(ctx, user)

      assert {:ok, %{active: false}, {:revoked, [_session]}} = deactivate(ctx, user)

      user = Repo.reload(user)
      assert user.disabled_at
      refute Repo.get_by(OrganizationMember, user_id: user.id)
      refute Repo.get_by(WorkspaceMember, user_id: user.id, workspace_id: ctx.workspace.id)
      refute Repo.get_by(BoardUser, user_id: user.id, board_id: access.board.id)
      assert revoked?(access.org_token)
      assert revoked?(access.personal_token)
      assert UserToken |> where([t], t.user_id == ^user.id) |> Repo.all() == []

      assert [event] = AuditLog.list_events(action: :scim_user_deprovisioned)
      assert event.metadata["disabled"] == true
      assert event.metadata["reason"] == "deactivated"
      assert event.metadata["api_credentials_revoked"] == 1
      assert event.organization_id == ctx.organization.id

      # Still readable, as inactive, and running it again changes nothing.
      assert {:ok, %{active: false}} = SCIM.get_user(ctx.token, user.id)
      assert {:ok, %{active: false}, :none} = deactivate(ctx, user)
    end

    test "an unmanaged account loses only the Organization's access", ctx do
      user = user_fixture()
      organization_member_fixture(ctx.organization, user)
      access = member_with_access(ctx, user)

      assert {:ok, %{active: false}, {:live, [_session]}} = deactivate(ctx, user)

      user = Repo.reload(user)
      assert is_nil(user.disabled_at)
      refute Repo.get_by(OrganizationMember, user_id: user.id)
      refute Repo.get_by(BoardUser, user_id: user.id, board_id: access.board.id)
      assert revoked?(access.org_token)
      refute revoked?(access.personal_token)
      assert [_session] = Accounts.list_session_tokens(user)
      assert %UserLink{} = UserLink.get(ctx.organization.id, user.id)
    end

    test "PUT with active false deprovisions too", ctx do
      %{user: user} = create!(ctx)

      assert {:ok, %{active: false}, {:revoked, []}} =
               SCIM.replace_user(ctx.token, user.id, %{
                 "userName" => user.email,
                 "active" => false
               })
    end

    test "the last org-admin with other members is refused and nothing changes", ctx do
      create!(ctx)

      assert deactivate(ctx, ctx.org_admin) == {:error, :last_org_admin}
      assert Organizations.org_admin?(ctx.org_admin, ctx.organization.id)
      assert SCIM.delete_user(ctx.token, ctx.org_admin.id) == {:error, :last_org_admin}
    end

    test "a site admin is never disabled", ctx do
      admin = admin_fixture()
      organization_member_fixture(ctx.organization, admin)

      {:ok, _} =
        admin |> User.managed_by_changeset(ctx.organization.id) |> Repo.update()

      assert {:ok, %{active: false}, {:live, _}} = deactivate(ctx, admin)
      assert is_nil(Repo.reload(admin).disabled_at)
      refute Organizations.member?(admin, ctx.organization.id)
    end

    test "a member whose account is already disabled still loses the Organization's access",
         ctx do
      %{user: user} = create!(ctx)
      access = member_with_access(ctx, user)
      {:ok, user} = user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()
      assert {:ok, %{active: false, member: true}} = SCIM.get_user(ctx.token, user.id)

      assert {:ok, %{active: false, member: false}, _sessions} = deactivate(ctx, user)

      refute Repo.get_by(OrganizationMember, user_id: user.id)
      refute Repo.get_by(WorkspaceMember, user_id: user.id, workspace_id: ctx.workspace.id)
      refute Repo.get_by(BoardUser, user_id: user.id, board_id: access.board.id)
      assert revoked?(access.org_token)
    end

    test "a refused deactivation writes none of the request's other changes", ctx do
      create!(ctx)

      body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "externalId", "value" => "ext-admin"},
          %{"op" => "replace", "path" => "active", "value" => false}
        ]
      }

      assert SCIM.patch_user(ctx.token, ctx.org_admin.id, body) == {:error, :last_org_admin}
      assert is_nil(UserLink.get(ctx.organization.id, ctx.org_admin.id))
      assert AuditLog.list_events(action: :scim_user_updated) == []
    end

    test "deactivating a linked user moves the link's updated_at, which the resource reports",
         ctx do
      user = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(ctx.organization, user)
      {:ok, _link} = UserLink.upsert(ctx.organization.id, user.id, "ext-9")
      past = ~U[2020-01-01 00:00:00Z]

      {1, _} =
        UserLink
        |> where([l], l.user_id == ^user.id)
        |> Repo.update_all(set: [updated_at: past])

      assert {:ok, %{link: link}, _sessions} = deactivate(ctx, user)
      assert DateTime.after?(link.updated_at, past)
    end

    test "a former member who rejoined outside SCIM and was removed again is not found", ctx do
      user = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)
      assert %UserLink{deprovisioned_at: %DateTime{}} = UserLink.get(ctx.organization.id, user.id)

      # Rejoins through the console rather than SCIM, then is removed there.
      assert {:ok, _} = Organizations.add_member(ctx.organization, user, :member)
      assert %UserLink{deprovisioned_at: nil} = UserLink.get(ctx.organization.id, user.id)
      assert {:ok, _} = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, user.id)

      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}
    end

    test "a former member who joined another Organization and left it is not found", ctx do
      user = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)

      # Joins another Organization, which clears this Organization's mark,
      # then leaves it again.
      assert {:ok, _} = Organizations.add_member(organization_fixture(), user, :member)
      assert %UserLink{deprovisioned_at: nil} = UserLink.get(ctx.organization.id, user.id)
      OrganizationMember |> Repo.get_by!(user_id: user.id) |> Repo.delete!()

      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}
    end

    test "SCIM never re-enables a managed account a site admin disabled", ctx do
      %{user: user} = create!(ctx)
      {:ok, _} = user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()

      assert {:ok, %{active: false}, _sessions} = deactivate(ctx, user)
      assert reactivate(ctx, user) == {:error, :user_disabled}
      assert Repo.reload(user).disabled_at

      assert SCIM.create_user(ctx.token, %{"userName" => user.email}) == {:error, :user_disabled}
    end

    test "a former member the Organization removed outside SCIM is not found", ctx do
      %{user: user} = create!(ctx)
      assert {:ok, _} = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, user.id)

      assert %UserLink{deprovisioned_at: nil} = UserLink.get(ctx.organization.id, user.id)
      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}

      assert {:ok, %{total: 0}} =
               SCIM.list_users(ctx.token, %{"filter" => ~s(userName eq "#{user.email}")})

      assert reactivate(ctx, user) == {:error, :not_found}
      assert SCIM.delete_user(ctx.token, user.id) == {:error, :not_found}
    end

    test "re-activation clears the deprovisioned mark, so a later removal hides the user",
         ctx do
      %{user: user} = create!(ctx)
      {:ok, _record, _sessions} = deactivate(ctx, user)
      assert %UserLink{deprovisioned_at: %DateTime{}} = UserLink.get(ctx.organization.id, user.id)

      {:ok, _record, :none} = reactivate(ctx, user)
      assert %UserLink{deprovisioned_at: nil} = UserLink.get(ctx.organization.id, user.id)

      assert {:ok, _} = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, user.id)
      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}
    end

    test "deleting detaches the link, so the user is no longer found", ctx do
      %{user: user} = create!(ctx)

      assert {:ok, {:revoked, []}} = SCIM.delete_user(ctx.token, user.id)
      assert Repo.reload(user).disabled_at
      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}

      assert %UserLink{deprovisioned_at: nil, external_id: nil, scim_disabled_at: %DateTime{}} =
               UserLink.get(ctx.organization.id, user.id)

      assert [event] = AuditLog.list_events(action: :scim_user_deprovisioned)
      assert event.metadata["reason"] == "deleted"

      # A user deactivated first is no longer found after a DELETE either.
      %{user: other} = create!(ctx)
      {:ok, _record, _sessions} = deactivate(ctx, other)
      assert {:ok, {:revoked, []}} = SCIM.delete_user(ctx.token, other.id)
      assert SCIM.get_user(ctx.token, other.id) == {:error, :not_found}
    end
  end

  describe "re-activation" do
    test "restores the membership and re-enables a managed account, not its tokens", ctx do
      %{user: user} = create!(ctx)
      access = member_with_access(ctx, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)

      assert {:ok, %{active: true}, :none} = reactivate(ctx, user)

      user = Repo.reload(user)
      assert is_nil(user.disabled_at)

      assert %OrganizationMember{role: :member} =
               Repo.get_by(OrganizationMember,
                 user_id: user.id,
                 organization_id: ctx.organization.id
               )

      assert revoked?(access.org_token)
      assert revoked?(access.personal_token)

      assert [_created, event] =
               AuditLog.list_events([action: :scim_user_provisioned], order: :asc)

      assert event.metadata["outcome"] == "reactivated"
    end

    test "re-activates an unmanaged account that was deprovisioned", ctx do
      user = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)

      assert {:ok, %{active: true}, :none} = reactivate(ctx, user)
      assert Organizations.member?(user, ctx.organization.id)
    end

    test "is refused for an unmanaged account outside the verified domains", ctx do
      user = user_fixture()
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)

      assert reactivate(ctx, user) == {:error, :domain_not_verified}
      refute Organizations.member?(user, ctx.organization.id)
    end

    test "is refused once the user joined another Organization", ctx do
      user = user_fixture()
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)
      organization_member_fixture(organization_fixture(), user)

      # The user is no longer the token's to reach.
      assert reactivate(ctx, user) == {:error, :not_found}
    end

    test "is refused for a disabled account the Organization does not manage", ctx do
      user = user_fixture(%{email: email(ctx.domain)})
      organization_member_fixture(ctx.organization, user)
      {:ok, _record, _sessions} = deactivate(ctx, user)
      {:ok, _} = user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()

      assert reactivate(ctx, user) == {:error, :user_disabled}
    end
  end

  describe "re-creating a deleted user" do
    test "a POST with the userName of a managed user a DELETE removed re-activates it", ctx do
      %{user: user} = create!(ctx)
      assert {:ok, _sessions} = SCIM.delete_user(ctx.token, user.id)
      assert SCIM.get_user(ctx.token, user.id) == {:error, :not_found}

      assert {:ok, %{user: again, active: true, link: %{external_id: "ext-2"}}} =
               SCIM.create_user(ctx.token, %{"userName" => user.email, "externalId" => "ext-2"})

      assert again.id == user.id
      assert is_nil(again.disabled_at)
      assert Organizations.member?(again, ctx.organization.id)

      assert [_created, event] =
               AuditLog.list_events([action: :scim_user_provisioned], order: :asc)

      assert event.metadata["outcome"] == "reactivated"
    end
  end

  describe "name parts" do
    defp parts(ctx, user) do
      {:ok, %{user: user, link: link}} = SCIM.get_user(ctx.token, user.id)
      UserMapping.name_parts(user, link)
    end

    defp name_body(given, family),
      do: %{"name" => %{"givenName" => given, "familyName" => family}}

    test "a multi-word given name reads back as sent, on POST and on PUT", ctx do
      %{user: user} = create!(ctx, name_body("Mary Ann", "Smith"))
      assert user.name == "Mary Ann Smith"
      assert parts(ctx, user) == %{given: "Mary Ann", family: "Smith"}

      body = Map.merge(%{"userName" => user.email}, name_body("Jo Ellen", "Lee"))

      assert {:ok, %{user: %{name: "Jo Ellen Lee"}}, :none} =
               SCIM.replace_user(ctx.token, user.id, body)

      assert parts(ctx, user) == %{given: "Jo Ellen", family: "Lee"}
    end

    test "a PATCH of one name part keeps the other, in the Entra and Okta forms", ctx do
      %{user: user} = create!(ctx, name_body("Mary Ann", "Smith"))

      entra = %{
        "Operations" => [%{"op" => "Replace", "path" => "name.givenName", "value" => "Ada"}]
      }

      assert {:ok, %{user: %{name: "Ada Smith"}}, :none} =
               SCIM.patch_user(ctx.token, user.id, entra)

      assert parts(ctx, user) == %{given: "Ada", family: "Smith"}

      okta = %{
        "Operations" => [
          %{"op" => "replace", "value" => %{"name" => %{"familyName" => "King Noel"}}}
        ]
      }

      assert {:ok, %{user: %{name: "Ada King Noel"}}, :none} =
               SCIM.patch_user(ctx.token, user.id, okta)

      assert parts(ctx, user) == %{given: "Ada", family: "King Noel"}
      assert [_first, event] = AuditLog.list_events([action: :scim_user_updated], order: :asc)
      assert event.metadata["fields"] == ["name"]
    end

    test "parts that no longer make up the name fall back to splitting it", ctx do
      %{user: user} = create!(ctx, name_body("Mary Ann", "Smith"))

      body = %{
        "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "Mae West"}]
      }

      assert {:ok, %{user: %{name: "Mae West"}}, :none} =
               SCIM.patch_user(ctx.token, user.id, body)

      assert parts(ctx, user) == %{given: "Mae", family: "West"}
    end

    test "an unmanaged user's parts are not kept", ctx do
      user = user_fixture(%{name: "Own Name"})
      organization_member_fixture(ctx.organization, user)

      body = %{
        "Operations" => [%{"op" => "replace", "path" => "name.givenName", "value" => "IdP"}]
      }

      assert {:ok, %{user: %{name: "Own Name"}}, :none} =
               SCIM.patch_user(ctx.token, user.id, body)

      assert is_nil(UserLink.get(ctx.organization.id, user.id))
    end
  end

  describe "changing attributes" do
    test "PATCH changes a managed user's name and the externalId, and is audited", ctx do
      %{user: user} = create!(ctx)

      body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "name.formatted", "value" => "New Name"},
          %{"op" => "replace", "path" => "externalId", "value" => "ext-2"}
        ]
      }

      assert {:ok, %{user: updated, link: link, active: true}, :none} =
               SCIM.patch_user(ctx.token, user.id, body)

      assert updated.name == "New Name"
      assert link.external_id == "ext-2"
      assert [event] = AuditLog.list_events(action: :scim_user_updated)
      assert event.metadata["fields"] == ["name", "external_id"]
    end

    test "an unmanaged user's name is left alone", ctx do
      user = user_fixture(%{name: "Own Name"})
      organization_member_fixture(ctx.organization, user)

      assert {:ok, %{user: %{name: "Own Name"}}, :none} =
               SCIM.replace_user(ctx.token, user.id, %{
                 "userName" => user.email,
                 "displayName" => "IdP Name"
               })
    end

    test "userName cannot change", ctx do
      %{user: user} = create!(ctx)

      assert SCIM.replace_user(ctx.token, user.id, %{"userName" => email(ctx.domain)}) ==
               {:error, :mutability}

      assert SCIM.patch_user(ctx.token, user.id, %{
               "Operations" => [%{"op" => "replace", "path" => "userName", "value" => "x@y.z"}]
             }) == {:error, :mutability}
    end

    test "a PUT without active or externalId changes neither", ctx do
      %{user: user} = create!(ctx)

      assert {:ok, %{active: true, link: %{external_id: "ext-1"}}, :none} =
               SCIM.replace_user(ctx.token, user.id, %{"userName" => user.email})

      assert AuditLog.list_events(action: :scim_user_updated) == []
    end

    test "an invalid name is refused", ctx do
      %{user: user} = create!(ctx)

      assert SCIM.patch_user(ctx.token, user.id, %{
               "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "a & b"}]
             }) == {:error, :invalid_value}
    end

    test "a malformed PATCH is refused", ctx do
      %{user: user} = create!(ctx)
      assert SCIM.patch_user(ctx.token, user.id, %{}) == {:error, :invalid_syntax}
    end
  end

  describe "groups" do
    test "list the Organization's active workspaces with their members", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      workspace_member_fixture(ctx.workspace, member)
      org_workspace_fixture(ctx.organization, %{archived_at: DateTime.utc_now(:second)})
      org_workspace_fixture(organization_fixture())

      assert {:ok, %{total: 1, records: [%{workspace: workspace, members: members}]}} =
               SCIM.list_groups(ctx.token, %{})

      assert workspace.id == ctx.workspace.id
      assert [%{user_id: user_id}] = members
      assert user_id == member.id

      assert {:ok, %{records: [%{members: nil}]}} =
               SCIM.list_groups(ctx.token, %{"excludedAttributes" => "members"})

      assert {:ok, %{total: 1}} =
               SCIM.list_groups(ctx.token, %{"filter" => ~s(displayName eq "#{workspace.name}")})

      assert {:ok, %{total: 0}} =
               SCIM.list_groups(ctx.token, %{"filter" => ~s(displayName eq "nope")})

      assert SCIM.list_groups(ctx.token, %{"filter" => "id pr"}) == {:error, :invalid_filter}
    end

    test "never reach a personal workspace or another Organization's", ctx do
      other = org_workspace_fixture(organization_fixture())
      personal = personal_workspace_fixture(ctx.org_admin)

      for id <- [other.id, personal.id, "x"] do
        assert SCIM.get_group(ctx.token, id) == {:error, :not_found}
        assert SCIM.patch_group(ctx.token, id, %{}) == {:error, :not_found}
      end
    end

    test "PATCH adds Organization members with role member and audits", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      body = %{
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "#{member.id}"}]}
        ]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok

      assert %WorkspaceMember{role: :member} =
               Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: member.id)

      assert [event] = AuditLog.list_events(action: :scim_group_updated)
      assert event.metadata["added_count"] == 1
      assert event.metadata["removed_count"] == 0

      # Adding again changes nothing and records nothing.
      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok
      assert [_event] = AuditLog.list_events(action: :scim_group_updated)
    end

    test "PATCH that changes the members moves the Group's updated_at", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      past = ~U[2020-01-01 00:00:00Z]

      {1, _} =
        Workspace
        |> where([w], w.id == ^ctx.workspace.id)
        |> Repo.update_all(set: [updated_at: past])

      body = %{
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "#{member.id}"}]}
        ]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok
      assert DateTime.after?(Repo.get!(Workspace, ctx.workspace.id).updated_at, past)

      # A PATCH that changes nothing leaves it.
      {1, _} =
        Workspace
        |> where([w], w.id == ^ctx.workspace.id)
        |> Repo.update_all(set: [updated_at: past])

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok
      assert Repo.get!(Workspace, ctx.workspace.id).updated_at == past
    end

    test "PATCH refuses users outside the Organization", ctx do
      outsider = user_fixture()

      for value <- ["#{outsider.id}", "999999999", "x"] do
        body = %{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => [%{"value" => value}]}
          ]
        }

        assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == {:error, :invalid_member}
      end

      refute Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: outsider.id)
    end

    test "PATCH removes members with their board access in the workspace", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      access = member_with_access(ctx, member)

      body = %{
        "Operations" => [%{"op" => "remove", "path" => ~s(members[value eq "#{member.id}"])}]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok

      refute Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: member.id)
      refute Repo.get_by(BoardUser, board_id: access.board.id, user_id: member.id)
      assert revoked?(access.org_token)
      refute revoked?(access.personal_token)
      assert Organizations.member?(member, ctx.organization.id)
    end

    test "replace computes the difference, and remove without a value empties the Group", ctx do
      [keep, drop, add] = for _ <- 1..3, do: user_fixture()
      Enum.each([keep, drop, add], &organization_member_fixture(ctx.organization, &1))
      workspace_member_fixture(ctx.workspace, keep)
      workspace_member_fixture(ctx.workspace, drop, :guest)

      body = %{
        "Operations" => [
          %{
            "op" => "replace",
            "path" => "members",
            "value" => [%{"value" => "#{keep.id}"}, %{"value" => "#{add.id}"}]
          }
        ]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, body) == :ok

      query =
        from(m in WorkspaceMember, where: m.workspace_id == ^ctx.workspace.id, select: m.user_id)

      ids = Repo.all(query)

      assert Enum.sort(ids) == Enum.sort([keep.id, add.id])

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, %{
               "Operations" => [%{"op" => "remove", "path" => "members"}]
             }) == :ok

      assert WorkspaceMember |> where([m], m.workspace_id == ^ctx.workspace.id) |> Repo.all() ==
               []
    end

    test "an archived workspace gains no members but can lose them", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      archived =
        org_workspace_fixture(ctx.organization, %{archived_at: DateTime.utc_now(:second)})

      workspace_member_fixture(archived, member)
      newcomer = user_fixture()
      organization_member_fixture(ctx.organization, newcomer)

      add = %{
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "#{newcomer.id}"}]}
        ]
      }

      assert SCIM.patch_group(ctx.token, archived.id, add) == {:error, :mutability}

      remove = %{
        "Operations" => [
          %{"op" => "remove", "path" => "members", "value" => [%{"value" => "#{member.id}"}]}
        ]
      }

      assert SCIM.patch_group(ctx.token, archived.id, remove) == :ok
      assert {:ok, %{members: []}} = SCIM.get_group(ctx.token, archived.id)
    end

    test "a Group cannot be renamed, but repeating its name is fine", ctx do
      rename = %{
        "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "New"}]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, rename) == {:error, :mutability}

      same = %{
        "Operations" => [
          %{"op" => "replace", "value" => %{"displayName" => ctx.workspace.name}}
        ]
      }

      assert SCIM.patch_group(ctx.token, ctx.workspace.id, same) == :ok
      assert SCIM.patch_group(ctx.token, ctx.workspace.id, %{}) == {:error, :invalid_syntax}
    end
  end
end
