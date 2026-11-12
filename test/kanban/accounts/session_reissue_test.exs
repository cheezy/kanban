defmodule Kanban.Accounts.SessionReissueTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.SessionReissue
  alias Kanban.Accounts.UserToken

  setup do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    offset_user_token(token, -10, :day)
    %{user: user, token: token}
  end

  describe "reissue/3" do
    test "mints one successor and links the replaced token to it", %{user: user, token: token} do
      assert {:ok, successor, replaced_id} = SessionReissue.reissue(user, token, 3600)
      assert successor != token

      assert %UserToken{token: ^token, replaced_by_id: successor_id, inserted_at: inserted_at} =
               Repo.get(UserToken, replaced_id)

      assert is_integer(successor_id)
      assert Repo.get(UserToken, successor_id).token == successor
      assert Accounts.get_user_by_session_token(successor)
      assert Accounts.get_user_by_session_token(token)

      # The replaced token is left valid for the grace period and no longer.
      expires_at = DateTime.add(inserted_at, 14, :day)
      assert DateTime.diff(expires_at, DateTime.utc_now(), :second) in 3590..3600
    end

    test "a replay of the replaced token is handed the same successor", %{
      user: user,
      token: token
    } do
      {:ok, successor, _replaced_id} = SessionReissue.reissue(user, token, 3600)

      assert {:ok, ^successor, nil} = SessionReissue.reissue(user, token, 3600)
      assert {:ok, ^successor, nil} = SessionReissue.reissue(user, token, 3600)
      assert length(Accounts.list_session_tokens(user)) == 2
    end

    test "revoking the successor takes the replaced token with it", %{user: user, token: token} do
      {:ok, successor, _replaced_id} = SessionReissue.reissue(user, token, 3600)
      UserToken |> where([t], t.token == ^successor) |> Repo.delete_all()

      # The cascade took the replaced token with its successor.
      refute Accounts.get_user_by_session_token(token)
      assert {:error, :not_found} = SessionReissue.reissue(user, token, 3600)
    end

    test "returns :not_found for an unknown token", %{user: user} do
      assert {:error, :not_found} =
               SessionReissue.reissue(user, :crypto.strong_rand_bytes(32), 3600)
    end
  end

  describe "revoke_family/1" do
    test "deletes the token, the tokens it replaced and the tokens that replaced it", %{
      user: user,
      token: first
    } do
      {:ok, second, _id} = SessionReissue.reissue(user, first, 3600)
      offset_user_token(second, -10, :day)
      {:ok, third, _id} = SessionReissue.reissue(user, second, 3600)

      revoked = SessionReissue.revoke_family(second)

      assert revoked |> Enum.map(& &1.token) |> Enum.sort() == Enum.sort([first, second, third])
      assert Enum.all?(revoked, &(&1.user_id == user.id))
      for t <- [first, second, third], do: refute(Accounts.get_user_by_session_token(t))
    end

    test "leaves other sessions alone", %{user: user, token: token} do
      other = Accounts.generate_user_session_token(user)
      SessionReissue.revoke_family(token)

      assert Accounts.get_user_by_session_token(other)
    end

    test "returns [] for an unknown token" do
      unknown = :crypto.strong_rand_bytes(32)
      assert SessionReissue.revoke_family(unknown) == []
    end
  end

  describe "revoke_replaced/1" do
    test "deletes a replaced token and returns it", %{user: user, token: token} do
      {:ok, successor, replaced_id} = SessionReissue.reissue(user, token, 3600)

      assert SessionReissue.revoke_replaced(replaced_id) == token
      refute Accounts.get_user_by_session_token(token)
      assert Accounts.get_user_by_session_token(successor)
      assert SessionReissue.revoke_replaced(replaced_id) == nil
    end

    test "leaves a token that was never replaced alone", %{token: token} do
      %UserToken{id: id} = Repo.get_by(UserToken, token: token)

      assert SessionReissue.revoke_replaced(id) == nil
      assert Accounts.get_user_by_session_token(token)
    end
  end
end
