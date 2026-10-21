defmodule Kanban.ApiTokensTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken

  require Ecto.Query

  describe "api_tokens" do
    @valid_attrs %{
      name: "Test Token",
      agent_model: "claude-3-opus",
      agent_version: "v1.0",
      agent_purpose: "Task automation"
    }
    @invalid_attrs %{name: nil}

    test "list_api_tokens/1 returns all api_tokens for a board" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, _plain_text}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      assert [found_token] = ApiTokens.list_api_tokens(board)
      assert found_token.id == api_token.id
    end

    test "list_api_tokens/1 does not return other boards' tokens" do
      user1 = user_fixture()
      user2 = user_fixture()
      board1 = board_fixture(user1)
      board2 = board_fixture(user2)
      {:ok, {_api_token, _plain_text}} = ApiTokens.create_api_token(user1, board1, @valid_attrs)
      assert [] = ApiTokens.list_api_tokens(board2)
    end

    test "get_api_token!/1 returns the api_token with given id" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, _plain_text}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      assert ApiTokens.get_api_token!(api_token.id).id == api_token.id
    end

    test "get_api_token_by_token/1 returns {:ok, token} for valid non-revoked token" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, {_api_token, plain_text_token}} =
        ApiTokens.create_api_token(user, board, @valid_attrs)

      assert {:ok, found_token} = ApiTokens.get_api_token_by_token(plain_text_token)
      assert found_token.name == "Test Token"
      assert found_token.user.id == user.id
      assert found_token.board.id == board.id
    end

    test "get_api_token_by_token/1 returns {:error, :not_found} for invalid token" do
      assert {:error, :not_found} = ApiTokens.get_api_token_by_token("invalid_token")
    end

    test "get_api_token_by_token/1 returns {:error, :revoked} for revoked token" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, plain_text_token}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      {:ok, _revoked} = ApiTokens.revoke_api_token(api_token)
      assert {:error, :revoked} = ApiTokens.get_api_token_by_token(plain_text_token)
    end

    test "create_api_token/3 defaults a bounded expires_at ~90 days out (D107)" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, _plain}} = ApiTokens.create_api_token(user, board, @valid_attrs)

      assert %DateTime{} = api_token.expires_at
      days = DateTime.diff(api_token.expires_at, DateTime.utc_now(), :day)
      assert days in 89..90
    end

    test "get_api_token_by_token/1 returns {:error, :expired} for an expired token (D107)" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, plain_text_token}} = ApiTokens.create_api_token(user, board, @valid_attrs)

      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      api_token
      |> Ecto.Changeset.change(expires_at: past)
      |> Kanban.Repo.update!()

      assert {:error, :expired} = ApiTokens.get_api_token_by_token(plain_text_token)
    end

    test "get_api_token_by_token/1 returns {:error, :user_disabled} when the owner is disabled" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, {_api_token, plain_text_token}} =
        ApiTokens.create_api_token(user, board, @valid_attrs)

      assert {:ok, _} = ApiTokens.get_api_token_by_token(plain_text_token)

      {:ok, _} = Kanban.Accounts.disable_user(user, admin_fixture())

      assert {:error, :user_disabled} = ApiTokens.get_api_token_by_token(plain_text_token)
    end

    test "get_api_token_by_token/1 accepts the token again once the owner is re-enabled" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, {_api_token, plain_text_token}} =
        ApiTokens.create_api_token(user, board, @valid_attrs)

      {:ok, disabled} = Kanban.Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Kanban.Accounts.enable_user(disabled, admin_fixture())

      assert {:ok, _found} = ApiTokens.get_api_token_by_token(plain_text_token)
    end

    test "get_api_token_by_token/1 still accepts a legacy token with nil expires_at (D107)" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, plain_text_token}} = ApiTokens.create_api_token(user, board, @valid_attrs)

      api_token
      |> Ecto.Changeset.change(expires_at: nil)
      |> Kanban.Repo.update!()

      assert {:ok, _found} = ApiTokens.get_api_token_by_token(plain_text_token)
    end

    test "create_api_token/3 with valid data creates an api_token" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, {%ApiToken{} = api_token, plain_text_token}} =
               ApiTokens.create_api_token(user, board, @valid_attrs)

      assert api_token.name == "Test Token"
      assert api_token.agent_model == "claude-3-opus"
      assert api_token.agent_version == "v1.0"
      assert api_token.agent_purpose == "Task automation"
      assert api_token.user_id == user.id
      assert api_token.board_id == board.id
      assert is_binary(plain_text_token)
      assert String.starts_with?(plain_text_token, "stride_")
      assert is_binary(api_token.token_hash)
    end

    test "create_api_token/3 with invalid data returns error changeset" do
      user = user_fixture()
      board = board_fixture(user)
      assert {:error, %Ecto.Changeset{}} = ApiTokens.create_api_token(user, board, @invalid_attrs)
    end

    test "create_api_token/3 returns a changeset, never a database error, for oversized text" do
      user = user_fixture()
      board = board_fixture(user)
      long = String.duplicate("a", 256)

      for attrs <- [
            %{name: long},
            %{name: "Agent", agent_model: long},
            %{name: "Agent", agent_version: long},
            %{name: "Agent", agent_capabilities: ["testing", long]}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 ApiTokens.create_api_token(user, board, attrs)
      end

      assert ApiTokens.list_api_tokens(board) == []
    end

    test "create_api_token/2 defaults attrs to an empty map and fails name validation" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiTokens.create_api_token(user, board)

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "revoke_api_token/1 marks the token as revoked" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, _plain_text}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      assert {:ok, %ApiToken{} = revoked_token} = ApiTokens.revoke_api_token(api_token)
      assert revoked_token.revoked_at != nil
    end

    test "delete_api_token/1 deletes the api_token" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {api_token, _plain_text}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      assert {:ok, %ApiToken{}} = ApiTokens.delete_api_token(api_token)
      assert_raise Ecto.NoResultsError, fn -> ApiTokens.get_api_token!(api_token.id) end
    end

    test "change_api_token/1 returns an api_token changeset" do
      api_token = %ApiToken{}
      assert %Ecto.Changeset{} = ApiTokens.change_api_token(api_token)
    end

    test "token generation creates unique tokens" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {_token1, plain1}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      {:ok, {_token2, plain2}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      refute plain1 == plain2
    end

    test "token hash prevents duplicate tokens" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {token1, _plain}} = ApiTokens.create_api_token(user, board, @valid_attrs)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%ApiToken{
          name: "Duplicate",
          token_hash: token1.token_hash,
          user_id: user.id,
          board_id: board.id
        })
      end
    end

    test "revoke_user_tokens_for_board/2 revokes only the active tokens for that board and user (W1430)" do
      user = user_fixture()
      other_user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)

      {:ok, {t1, _}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      {:ok, {t2, _}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      {:ok, {other_board_token, _}} = ApiTokens.create_api_token(user, other_board, @valid_attrs)
      {:ok, {other_user_token, _}} = ApiTokens.create_api_token(other_user, board, @valid_attrs)

      assert {2, nil} = ApiTokens.revoke_user_tokens_for_board(board.id, user.id)

      assert Repo.get!(ApiToken, t1.id).revoked_at
      assert Repo.get!(ApiToken, t2.id).revoked_at
      refute Repo.get!(ApiToken, other_board_token.id).revoked_at
      refute Repo.get!(ApiToken, other_user_token.id).revoked_at
    end

    test "revoke_user_tokens_for_board/2 leaves already-revoked tokens untouched (W1430)" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {token, _}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      {:ok, revoked} = ApiTokens.revoke_api_token(token)
      original_revoked_at = revoked.revoked_at

      assert {0, nil} = ApiTokens.revoke_user_tokens_for_board(board.id, user.id)
      assert Repo.get!(ApiToken, token.id).revoked_at == original_revoked_at
    end
  end

  describe "stamp_last_agent_name/2 (D137)" do
    defp token_fixture do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {token, _plain}} = ApiTokens.create_api_token(user, board, %{name: "Stamp Token"})
      token
    end

    test "stamps a usable agent name onto the token" do
      token = token_fixture()

      assert :ok = ApiTokens.stamp_last_agent_name(token, "Claude Fable 5")
      assert ApiTokens.get_api_token!(token.id).last_agent_name == "Claude Fable 5"
    end

    test "overwrites a previously stamped name" do
      token = token_fixture()

      assert :ok = ApiTokens.stamp_last_agent_name(token, "First Agent")
      assert :ok = ApiTokens.stamp_last_agent_name(token, "Second Agent")
      assert ApiTokens.get_api_token!(token.id).last_agent_name == "Second Agent"
    end

    test "skips nil, blank, and the Unknown placeholder" do
      token = token_fixture()

      for unusable <- [nil, "", "   ", "Unknown"] do
        assert :ok = ApiTokens.stamp_last_agent_name(token, unusable)
        assert ApiTokens.get_api_token!(token.id).last_agent_name == nil
      end
    end

    test "discards an over-length name without raising or failing" do
      token = token_fixture()
      oversized = String.duplicate("a", 256)

      assert :ok = ApiTokens.stamp_last_agent_name(token, oversized)
      assert ApiTokens.get_api_token!(token.id).last_agent_name == nil
    end

    test "usable_agent_name?/1 truth table" do
      assert ApiTokens.usable_agent_name?("Claude Fable 5")
      assert ApiTokens.usable_agent_name?("unknown")
      refute ApiTokens.usable_agent_name?("Unknown")
      refute ApiTokens.usable_agent_name?("")
      refute ApiTokens.usable_agent_name?("   ")
      refute ApiTokens.usable_agent_name?(nil)
      refute ApiTokens.usable_agent_name?(:agent)
    end

    test "usable_agent_name?/1 refuses invisible, NUL-bearing and invalid UTF-8 names" do
      refute ApiTokens.usable_agent_name?("\u200b")
      refute ApiTokens.usable_agent_name?("\u200e\u202e \ufeff")
      refute ApiTokens.usable_agent_name?("Claude\u0000")
      refute ApiTokens.usable_agent_name?(<<0xFF, 0x41>>)
      assert ApiTokens.usable_agent_name?("\u200bClaude")
    end
  end

  describe "revoke_all_user_tokens/1 (W2247)" do
    test "revokes every active token of the user on every board, and only theirs" do
      user = user_fixture()
      other = user_fixture()
      attrs = %{name: "Agent", agent_model: "claude", agent_version: "v1", agent_purpose: "work"}
      {:ok, {first, _}} = ApiTokens.create_api_token(user, board_fixture(user), attrs)
      {:ok, {second, _}} = ApiTokens.create_api_token(user, board_fixture(user), attrs)
      {:ok, {already, _}} = ApiTokens.create_api_token(user, board_fixture(user), attrs)
      {:ok, _} = ApiTokens.revoke_api_token(already)
      already_at = Repo.get!(ApiToken, already.id).revoked_at
      {:ok, {theirs, _}} = ApiTokens.create_api_token(other, board_fixture(other), attrs)

      assert ApiTokens.revoke_all_user_tokens(user.id) == {2, nil}

      assert Repo.get!(ApiToken, first.id).revoked_at
      assert Repo.get!(ApiToken, second.id).revoked_at
      assert Repo.get!(ApiToken, already.id).revoked_at == already_at
      refute Repo.get!(ApiToken, theirs.id).revoked_at
      assert ApiTokens.revoke_all_user_tokens(user.id) == {0, nil}
    end
  end

  describe "token_bulk_revoked telemetry" do
    @bulk_revoked [:kanban, :api, :token_bulk_revoked]

    test "bulk revoke with no tokens" do
      owner = user_fixture()
      member = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, member, :modify, owner)
      attach_telemetry(@bulk_revoked)

      assert {:ok, _} = Kanban.Boards.remove_user_from_board(board, member, owner)

      assert_received {:telemetry_event, @bulk_revoked, %{count: 0}, metadata}

      assert metadata == %{
               board_id: board.id,
               user_id: member.id,
               actor_user_id: owner.id,
               reason: :member_removed
             }
    end

    test "report_bulk_revocation/5 emits token_bulk_revoked with the number revoked" do
      attach_telemetry(@bulk_revoked)

      assert :ok = ApiTokens.report_bulk_revocation(1, 2, 3, 4, :read_only_access)

      assert_received {:telemetry_event, @bulk_revoked, %{count: 3},
                       %{board_id: 1, user_id: 2, actor_user_id: 4, reason: :read_only_access}}
    end

    test "revoke_user_tokens_for_board/2 emits nothing on its own, since it runs before commit" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {_token, _}} = ApiTokens.create_api_token(user, board, @valid_attrs)
      attach_telemetry(@bulk_revoked)

      assert {1, nil} = ApiTokens.revoke_user_tokens_for_board(board.id, user.id)
      refute_received {:telemetry_event, @bulk_revoked, _, _}
    end
  end

  describe "create_api_token_for_member/3" do
    @member_attrs %{name: "Board Token"}

    defp grant(board, user, access) do
      %Kanban.Boards.BoardUser{}
      |> Kanban.Boards.BoardUser.changeset(%{
        board_id: board.id,
        user_id: user.id,
        access: access
      })
      |> Kanban.Repo.insert!()
    end

    test "creates a token for an owner or a modify member" do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      grant(board, member, :modify)

      assert {:ok, {%ApiToken{}, _plain}} =
               ApiTokens.create_api_token_for_member(owner, board, @member_attrs)

      assert {:ok, {%ApiToken{user_id: member_id}, _plain}} =
               ApiTokens.create_api_token_for_member(member, board, @member_attrs)

      assert member_id == member.id
    end

    test "refuses a read-only member and a user without access, creating nothing" do
      board = board_fixture(user_fixture())
      reader = user_fixture()
      grant(board, reader, :read_only)

      assert ApiTokens.create_api_token_for_member(reader, board, @member_attrs) ==
               {:error, :unauthorized}

      assert ApiTokens.create_api_token_for_member(user_fixture(), board, @member_attrs) ==
               {:error, :unauthorized}

      assert ApiTokens.list_api_tokens(board) == []
    end

    test "creates a token for an org-admin through derived access, and not once removed" do
      organization = Kanban.OrganizationsFixtures.organization_fixture()
      workspace = Kanban.WorkspacesFixtures.org_workspace_fixture(organization)
      org_admin = user_fixture()

      Kanban.OrganizationsFixtures.organization_member_fixture(
        organization,
        org_admin,
        :org_admin
      )

      board = board_fixture(user_fixture())

      Kanban.Boards.Board
      |> Ecto.Query.where([b], b.id == ^board.id)
      |> Kanban.Repo.update_all(set: [workspace_id: workspace.id])

      assert {:ok, _created} =
               ApiTokens.create_api_token_for_member(org_admin, board, @member_attrs)

      Kanban.Organizations.OrganizationMember
      |> Ecto.Query.where([m], m.user_id == ^org_admin.id)
      |> Kanban.Repo.delete_all()

      assert ApiTokens.create_api_token_for_member(org_admin, board, @member_attrs) ==
               {:error, :unauthorized}
    end

    test "returns the changeset for invalid attributes" do
      owner = user_fixture()
      board = board_fixture(owner)

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_api_token_for_member(owner, board, @invalid_attrs)

      assert ApiTokens.list_api_tokens(board) == []
    end
  end

  describe "workspace tokens (W2220)" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      workspace = org_workspace_fixture(organization)
      board = workspace_board(workspace)

      %{organization: organization, admin: admin, workspace: workspace, board: board}
    end

    test "create_workspace_api_token/3 creates a workspace-scoped token with a 90-day expiry",
         %{admin: admin, workspace: workspace} do
      assert {:ok, {api_token, plain_text}} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      assert api_token.workspace_id == workspace.id
      assert api_token.board_id == nil
      assert api_token.user_id == admin.id
      assert String.starts_with?(plain_text, "stride_")
      assert api_token.token_hash == ApiToken.hash_token_string(plain_text)

      days = DateTime.diff(api_token.expires_at, DateTime.utc_now(), :day)
      assert days in 89..90
    end

    test "create_workspace_api_token/3 accepts a workspace id", %{admin: admin, workspace: ws} do
      assert {:ok, {api_token, _}} =
               ApiTokens.create_workspace_api_token(admin, Integer.to_string(ws.id), %{
                 name: "Fleet"
               })

      assert api_token.workspace_id == ws.id
    end

    test "create_workspace_api_token/3 ignores a crafted user_id and workspace_id",
         %{admin: admin, workspace: workspace, organization: organization} do
      other = user_fixture()
      other_workspace = org_workspace_fixture(organization)

      assert {:ok, {api_token, _}} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{
                 "name" => "Fleet",
                 "user_id" => other.id,
                 "workspace_id" => other_workspace.id
               })

      assert api_token.user_id == admin.id
      assert api_token.workspace_id == workspace.id
    end

    test "create_workspace_api_token/3 refuses members, guests, free users and other orgs' admins",
         %{organization: organization, workspace: workspace} do
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)

      guest = user_fixture()
      workspace_member_fixture(workspace, guest, :guest)

      free_user = user_fixture()

      foreign_admin = user_fixture()
      organization_member_fixture(organization_fixture(), foreign_admin, :org_admin)

      for user <- [member, guest, free_user, foreign_admin] do
        assert {:error, :unauthorized} =
                 ApiTokens.create_workspace_api_token(user, workspace, %{name: "Fleet"})
      end

      assert workspace_tokens(workspace) == []
    end

    test "create_workspace_api_token/3 refuses a disabled org-admin",
         %{admin: admin, workspace: workspace} do
      Kanban.Accounts.User
      |> Ecto.Query.where([u], u.id == ^admin.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      assert {:error, :unauthorized} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})
    end

    test "create_workspace_api_token/3 refuses a personal workspace", %{admin: admin} do
      personal = personal_workspace_fixture(admin)

      assert {:error, :unauthorized} =
               ApiTokens.create_workspace_api_token(admin, personal, %{name: "Fleet"})
    end

    test "create_workspace_api_token/3 refuses an archived workspace and a missing one",
         %{admin: admin, organization: organization} do
      archived = org_workspace_fixture(organization, archived_at: DateTime.utc_now(:second))

      assert {:error, :archived} =
               ApiTokens.create_workspace_api_token(admin, archived, %{name: "Fleet"})

      assert {:error, :unauthorized} =
               ApiTokens.create_workspace_api_token(admin, -1, %{name: "Fleet"})

      assert {:error, :unauthorized} =
               ApiTokens.create_workspace_api_token(admin, "abc", %{name: "Fleet"})
    end

    test "create_workspace_api_token/3 returns a changeset for invalid attributes",
         %{admin: admin, workspace: workspace} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{name: ""})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "create_workspace_api_token/3 returns a changeset for oversized text",
         %{admin: admin, workspace: workspace} do
      long = String.duplicate("a", 256)

      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{name: long})

      assert "should be at most 255 character(s)" in errors_on(changeset).name

      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiTokens.create_workspace_api_token(admin, workspace, %{
                 name: "Fleet",
                 agent_capabilities: [long]
               })

      assert errors_on(changeset).agent_capabilities == [
               "each capability must be at most 255 characters"
             ]

      assert ApiTokens.list_workspace_api_tokens(admin, workspace) == []
    end

    test "create_workspace_api_token/3 emits token_created and audits it",
         %{admin: admin, workspace: workspace} do
      attach_telemetry([:kanban, :api, :token_created])

      {:ok, {api_token, _}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      assert_receive {:telemetry_event, [:kanban, :api, :token_created], %{count: 1}, metadata}

      assert metadata == %{
               user_id: admin.id,
               workspace_id: workspace.id,
               token_id: api_token.id
             }

      assert [created] =
               Kanban.AuditLog.list_events(action: :api_token_created, actor_user_id: admin.id)

      assert created.metadata["token_id"] == api_token.id
      assert created.metadata["workspace_id"] == workspace.id
      assert created.organization_id == workspace.organization_id
    end

    test "the database rejects a token with both or neither of board_id and workspace_id",
         %{admin: admin, workspace: workspace, board: board} do
      both =
        ApiToken.workspace_changeset(%ApiToken{board_id: board.id}, %{
          name: "Both",
          user_id: admin.id,
          workspace_id: workspace.id
        })

      assert {:error, changeset} = Repo.insert(both)
      assert "a token belongs to exactly one board or workspace" in errors_on(changeset).board_id

      now = DateTime.utc_now(:second)

      assert_raise Postgrex.Error, ~r/api_tokens_board_xor_workspace/, fn ->
        Repo.insert_all("api_tokens", [
          %{
            name: "Neither",
            token_hash: "neither-#{System.unique_integer([:positive])}",
            user_id: admin.id,
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "list_workspace_api_tokens/2 lists only the workspace's tokens, newest first",
         %{admin: admin, workspace: workspace, organization: organization, board: board} do
      {:ok, {first, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})
      {:ok, {second, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "B"})

      other = org_workspace_fixture(organization)
      {:ok, _} = ApiTokens.create_workspace_api_token(admin, other, %{name: "Other"})
      {:ok, _} = ApiTokens.create_api_token(admin, board, %{name: "Board"})

      assert [listed_second, listed_first] = ApiTokens.list_workspace_api_tokens(admin, workspace)
      assert listed_second.id == second.id
      assert listed_first.id == first.id
      assert listed_first.user.id == admin.id
    end

    test "list_workspace_api_tokens/2 lists nothing for anyone who is not an org-admin",
         %{admin: admin, workspace: workspace, organization: organization} do
      {:ok, _} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      workspace_member_fixture(workspace, member, :member)

      foreign_admin = user_fixture()
      organization_member_fixture(organization_fixture(), foreign_admin, :org_admin)

      for user <- [member, foreign_admin, user_fixture()] do
        assert ApiTokens.list_workspace_api_tokens(user, workspace) == []
      end

      assert [_token] = ApiTokens.list_workspace_api_tokens(admin, workspace)
    end

    test "revoke_workspace_api_token/3 revokes the workspace's token for an org-admin",
         %{admin: admin, workspace: workspace} do
      {:ok, {api_token, plain}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})

      assert {:ok, revoked} = ApiTokens.revoke_workspace_api_token(admin, workspace, api_token.id)
      assert revoked.revoked_at
      assert {:error, :revoked} = ApiTokens.get_api_token_by_token(plain)

      # Backdate the revocation, so revoking again in the same second could not
      # pass by writing an equal timestamp: a revoked token is returned as is.
      revoked_at = DateTime.add(revoked.revoked_at, -3600, :second)

      ApiToken
      |> Ecto.Query.where([t], t.id == ^api_token.id)
      |> Repo.update_all(set: [revoked_at: revoked_at])

      assert {:ok, again} =
               ApiTokens.revoke_workspace_api_token(admin, workspace, "#{api_token.id}")

      assert again.revoked_at == revoked_at
      assert Repo.reload!(api_token).revoked_at == revoked_at
    end

    test "revoke_workspace_api_token/3 cannot reach another workspace's or a board token",
         %{admin: admin, workspace: workspace, organization: organization, board: board} do
      other = org_workspace_fixture(organization)
      {:ok, {foreign, _}} = ApiTokens.create_workspace_api_token(admin, other, %{name: "A"})
      {:ok, {board_token, _}} = ApiTokens.create_api_token(admin, board, %{name: "B"})

      assert {:error, :not_found} =
               ApiTokens.revoke_workspace_api_token(admin, workspace, foreign.id)

      assert {:error, :not_found} =
               ApiTokens.revoke_workspace_api_token(admin, workspace, board_token.id)

      assert {:error, :not_found} = ApiTokens.revoke_workspace_api_token(admin, workspace, "x")
      assert Repo.reload!(foreign).revoked_at == nil
      assert Repo.reload!(board_token).revoked_at == nil
    end

    test "revoke_workspace_api_token/3 refuses someone who is not an org-admin",
         %{admin: admin, workspace: workspace, organization: organization} do
      {:ok, {api_token, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})
      member = user_fixture()
      organization_member_fixture(organization, member, :member)

      assert {:error, :unauthorized} =
               ApiTokens.revoke_workspace_api_token(member, workspace, api_token.id)

      assert Repo.reload!(api_token).revoked_at == nil
    end

    test "revoke_user_workspace_tokens/2 revokes only that user's workspace tokens",
         %{admin: admin, workspace: workspace, organization: organization, board: board} do
      other_admin = user_fixture()
      organization_member_fixture(organization, other_admin, :org_admin)
      other = org_workspace_fixture(organization)

      {:ok, {mine, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})

      {:ok, {theirs, _}} =
        ApiTokens.create_workspace_api_token(other_admin, workspace, %{name: "B"})

      {:ok, {in_other, _}} = ApiTokens.create_workspace_api_token(admin, other, %{name: "C"})

      {:ok, {board_token, _}} = ApiTokens.create_api_token(admin, board, %{name: "D"})

      # A user belongs to one Organization, so create_workspace_api_token/3
      # cannot mint this one; insert it directly to pin the Organization scope.
      foreign_org_token =
        %ApiToken{}
        |> ApiToken.workspace_changeset(%{
          name: "E",
          user_id: admin.id,
          workspace_id: org_workspace_fixture(organization_fixture()).id
        })
        |> Repo.insert!()

      assert ApiTokens.revoke_user_workspace_tokens(admin.id, organization.id) == 2
      assert Repo.reload!(mine).revoked_at
      assert Repo.reload!(in_other).revoked_at
      refute Repo.reload!(theirs).revoked_at
      refute Repo.reload!(board_token).revoked_at
      refute Repo.reload!(foreign_org_token).revoked_at
    end

    test "get_api_token_by_token/1 preloads the workspace",
         %{admin: admin, workspace: workspace} do
      {:ok, {_, plain}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})

      assert {:ok, api_token} = ApiTokens.get_api_token_by_token(plain)
      assert api_token.workspace.id == workspace.id
      assert api_token.board == nil
      assert ApiToken.workspace_token?(api_token)
      assert ApiTokens.token_scope(api_token) == "workspace"
    end

    test "removing the org-admin from the Organization revokes their workspace tokens",
         %{admin: admin, workspace: workspace, organization: organization} do
      second_admin = user_fixture()
      organization_member_fixture(organization, second_admin, :org_admin)

      {:ok, {api_token, plain}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})

      assert {:ok, _} =
               Kanban.Organizations.remove_org_admin(admin_fixture(), organization, admin)

      assert Repo.reload!(api_token).revoked_at
      assert {:error, :revoked} = ApiTokens.get_api_token_by_token(plain)
    end

    test "removing the user from the workspace revokes their workspace token for it",
         %{admin: admin, workspace: workspace, organization: organization} do
      second_admin = user_fixture()
      organization_member_fixture(organization, second_admin, :org_admin)
      workspace_member_fixture(workspace, admin, :member)
      other = org_workspace_fixture(organization)

      {:ok, {here, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})
      {:ok, {there, _}} = ApiTokens.create_workspace_api_token(admin, other, %{name: "B"})

      assert {:ok, _} = Kanban.Workspaces.remove_member(second_admin, workspace, admin)

      assert Repo.reload!(here).revoked_at
      refute Repo.reload!(there).revoked_at
    end

    test "removing the user from the Organization through MembershipCascade revokes workspace tokens",
         %{admin: admin, workspace: workspace, organization: organization} do
      other = org_workspace_fixture(organization)
      {:ok, {here, _}} = ApiTokens.create_workspace_api_token(admin, workspace, %{name: "A"})
      {:ok, {there, _}} = ApiTokens.create_workspace_api_token(admin, other, %{name: "B"})

      {:ok, _} =
        Repo.transaction(fn ->
          Kanban.Workspaces.MembershipCascade.remove(admin.id, [workspace.id, other.id])
        end)

      assert Repo.reload!(here).revoked_at
      assert Repo.reload!(there).revoked_at
    end

    test "the token a create returns lists and resolves the same boards as one read back",
         %{admin: admin, workspace: workspace, board: board} do
      {:ok, {created, _plain}} =
        ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

      read_back = created |> Repo.reload!() |> Repo.preload([:board, :workspace, :user])

      assert [%{id: id}] = ApiTokens.list_token_boards(created)
      assert id == board.id
      assert ApiTokens.list_token_boards(created) == ApiTokens.list_token_boards(read_back)

      assert {:ok, %{id: ^id}} = ApiTokens.fetch_workspace_board(created, board.id)
      assert ApiTokens.fetch_workspace_board(created, -1) == :error
    end
  end

  describe "list_token_boards/1 on a board token" do
    test "lists its one board whether or not the board is loaded" do
      user = user_fixture()
      board = board_fixture(user)
      {:ok, {created, _plain}} = ApiTokens.create_api_token(user, board, %{"name" => "One"})

      reloaded = Repo.reload!(created)

      assert [%{id: id}] = ApiTokens.list_token_boards(reloaded)
      assert id == board.id
    end
  end

  # An AI Optimized board, owned by a new user, moved into `workspace`.
  # Every token of the workspace, read without the org-admin check
  # list_workspace_api_tokens/2 makes.
  defp workspace_tokens(workspace) do
    ApiToken
    |> Ecto.Query.where([t], t.workspace_id == ^workspace.id)
    |> Kanban.Repo.all()
  end

  defp workspace_board(workspace) do
    board = ai_optimized_board_fixture(user_fixture())

    {1, _} =
      Kanban.Boards.Board
      |> Ecto.Query.where([b], b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])

    Repo.reload!(board)
  end
end
