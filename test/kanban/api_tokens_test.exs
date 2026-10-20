defmodule Kanban.ApiTokensTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TelemetryHelpers

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
end
