defmodule Kanban.ApiTokensTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken

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
      {:ok, {_api_token, plain_text_token}} = ApiTokens.create_api_token(user, board, @valid_attrs)
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

    test "create_api_token/3 with valid data creates an api_token" do
      user = user_fixture()
      board = board_fixture(user)
      assert {:ok, {%ApiToken{} = api_token, plain_text_token}} = ApiTokens.create_api_token(user, board, @valid_attrs)
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
  end
end
