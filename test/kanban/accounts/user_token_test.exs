defmodule Kanban.Accounts.UserTokenTest do
  @moduledoc """
  Unit tests for the query builders in `Kanban.Accounts.UserToken` that
  aren't exercised through the higher-level `Accounts` flows — namely the
  context-filtered variant of `by_user_and_contexts_query/2`.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  describe "by_user_and_contexts_query/2 with an explicit context list" do
    setup do
      user = user_fixture()
      other = user_fixture()

      {_plain, session_token} = UserToken.build_session_token(user)
      {_plain, reset_token} = UserToken.build_email_token(user, "reset_password")
      {_plain, other_session} = UserToken.build_session_token(other)

      Repo.insert!(session_token)
      Repo.insert!(reset_token)
      Repo.insert!(other_session)

      %{user: user, other: other}
    end

    test "returns only the user's tokens whose context is in the list", %{user: user} do
      contexts =
        user
        |> UserToken.by_user_and_contexts_query(["session"])
        |> Repo.all()
        |> Enum.map(& &1.context)

      assert contexts == ["session"]
    end

    test "matches every listed context for the scoped user", %{user: user} do
      contexts =
        user
        |> UserToken.by_user_and_contexts_query(["session", "reset_password"])
        |> Repo.all()
        |> Enum.map(& &1.context)
        |> Enum.sort()

      assert contexts == ["reset_password", "session"]
    end

    test "never returns another user's tokens", %{user: user, other: other} do
      user_ids =
        user
        |> UserToken.by_user_and_contexts_query(["session", "reset_password"])
        |> Repo.all()
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()

      assert user_ids == [user.id]
      refute other.id in user_ids
    end
  end
end
