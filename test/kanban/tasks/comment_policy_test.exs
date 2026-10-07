defmodule Kanban.Tasks.CommentPolicyTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Tasks.CommentPolicy
  alias Kanban.Tasks.TaskComment

  setup do
    owner = user_fixture()
    modifier = user_fixture()
    reader = user_fixture()
    stranger = user_fixture()
    board = board_fixture(owner)

    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    %{
      board: board,
      owner: owner,
      modifier: modifier,
      reader: reader,
      stranger: stranger
    }
  end

  defp scope(user), do: Scope.for_user(user)
  defp authored_by(user), do: %TaskComment{author_user_id: user.id}

  describe "resolve/2" do
    test "captures the user id and access level for each role", ctx do
      for {user, access} <- [
            {ctx.owner, :owner},
            {ctx.modifier, :modify},
            {ctx.reader, :read_only},
            {ctx.stranger, nil}
          ] do
        assert user |> scope() |> CommentPolicy.resolve(ctx.board.id) == %{
                 user_id: user.id,
                 access: access
               }
      end
    end

    test "resolves a nil scope or a scope without a user to no access", %{board: board} do
      assert CommentPolicy.resolve(nil, board.id) == %{user_id: nil, access: nil}
      assert CommentPolicy.resolve(%Scope{user: nil}, board.id) == %{user_id: nil, access: nil}
    end
  end

  describe "allowed?/2 and allowed?/3" do
    test "lets only the author edit and the author or owner delete", ctx do
      owner = ctx.owner |> scope() |> CommentPolicy.resolve(ctx.board.id)
      modifier = ctx.modifier |> scope() |> CommentPolicy.resolve(ctx.board.id)

      assert CommentPolicy.allowed?(modifier, :edit, authored_by(ctx.modifier))
      refute CommentPolicy.allowed?(modifier, :edit, authored_by(ctx.reader))
      refute CommentPolicy.allowed?(owner, :edit, authored_by(ctx.reader))
      assert CommentPolicy.allowed?(owner, :delete, authored_by(ctx.reader))
      refute CommentPolicy.allowed?(modifier, :delete, authored_by(ctx.reader))
    end

    test "refuses everything for a viewer with no access, even on their own comment", ctx do
      former = %{user_id: ctx.stranger.id, access: nil}

      refute CommentPolicy.allowed?(former, :comment)
      refute CommentPolicy.allowed?(former, :edit, authored_by(ctx.stranger))
      refute CommentPolicy.allowed?(former, :delete, authored_by(ctx.stranger))
    end

    test "never treats a comment with no author as authored by an anonymous viewer" do
      anonymous_member = %{user_id: nil, access: :modify}

      refute CommentPolicy.allowed?(anonymous_member, :edit, %TaskComment{author_user_id: nil})
      refute CommentPolicy.allowed?(anonymous_member, :delete, %TaskComment{author_user_id: nil})
    end
  end

  describe "can_comment?/2" do
    test "is true for owner, modify and read-only members", ctx do
      for user <- [ctx.owner, ctx.modifier, ctx.reader] do
        assert user |> scope() |> CommentPolicy.can_comment?(ctx.board.id)
      end
    end

    test "is false for a user with no board membership", %{board: board, stranger: stranger} do
      refute stranger |> scope() |> CommentPolicy.can_comment?(board.id)
    end

    test "is false for a nil scope or a scope without a user", %{board: board} do
      refute CommentPolicy.can_comment?(nil, board.id)
      refute CommentPolicy.can_comment?(%Scope{user: nil}, board.id)
    end

    test "accepts a plain map scope shaped like Scope", %{board: board, reader: reader} do
      assert CommentPolicy.can_comment?(%{user: reader}, board.id)
    end

    test "is false for a nil board id", %{owner: owner} do
      refute owner |> scope() |> CommentPolicy.can_comment?(nil)
    end
  end

  describe "can_edit?/3" do
    test "is true only for the author", ctx do
      comment = authored_by(ctx.reader)

      assert ctx.reader |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
      refute ctx.owner |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
      refute ctx.modifier |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
      refute ctx.stranger |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
    end

    test "is false for a legacy comment with no author, even for the owner", ctx do
      comment = %TaskComment{author_user_id: nil}

      refute ctx.owner |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
    end

    test "is false for an author who is no longer a board member", ctx do
      comment = authored_by(ctx.reader)
      {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.reader, ctx.owner)

      refute ctx.reader |> scope() |> CommentPolicy.can_edit?(ctx.board.id, comment)
    end

    test "is false for a nil scope", %{board: board, reader: reader} do
      refute CommentPolicy.can_edit?(nil, board.id, authored_by(reader))
    end
  end

  describe "can_delete?/3" do
    test "is true for the author", ctx do
      for user <- [ctx.owner, ctx.modifier, ctx.reader] do
        assert user |> scope() |> CommentPolicy.can_delete?(ctx.board.id, authored_by(user))
      end
    end

    test "is true for the board owner on another user's comment", ctx do
      assert ctx.owner
             |> scope()
             |> CommentPolicy.can_delete?(ctx.board.id, authored_by(ctx.reader))
    end

    test "is true for the board owner on a legacy authorless comment", ctx do
      comment = %TaskComment{author_user_id: nil}

      assert ctx.owner |> scope() |> CommentPolicy.can_delete?(ctx.board.id, comment)
    end

    test "is false for modify and read-only members who are not the author", ctx do
      comment = authored_by(ctx.owner)

      refute ctx.modifier |> scope() |> CommentPolicy.can_delete?(ctx.board.id, comment)
      refute ctx.reader |> scope() |> CommentPolicy.can_delete?(ctx.board.id, comment)
      refute ctx.reader |> scope() |> CommentPolicy.can_delete?(ctx.board.id, %TaskComment{})
    end

    test "is false for a non-member, even one who authored the comment", ctx do
      stranger_scope = scope(ctx.stranger)

      refute CommentPolicy.can_delete?(stranger_scope, ctx.board.id, authored_by(ctx.stranger))
    end

    test "is false for an author removed from the board", ctx do
      comment = authored_by(ctx.modifier)
      {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.modifier, ctx.owner)

      refute ctx.modifier |> scope() |> CommentPolicy.can_delete?(ctx.board.id, comment)
    end

    test "is false for a nil scope", %{board: board, owner: owner} do
      refute CommentPolicy.can_delete?(nil, board.id, authored_by(owner))
    end
  end
end
