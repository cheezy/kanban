defmodule Kanban.Attachments.PolicyTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments.Policy
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards
  alias Kanban.Tasks.TaskComment

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    modifier = user_fixture()
    reader = user_fixture()
    stranger = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    %{board: board, owner: owner, modifier: modifier, reader: reader, stranger: stranger}
  end

  defp scope(user), do: Scope.for_user(user)

  test "allows upload for owner and modify, read for every member, delete for uploader or owner",
       %{board: board, owner: owner, modifier: modifier, reader: reader, stranger: stranger} do
    by_modifier = %TaskAttachment{uploaded_by_id: modifier.id}
    by_reader = %TaskAttachment{uploaded_by_id: reader.id}
    orphaned = %TaskAttachment{uploaded_by_id: nil}

    assert owner |> scope() |> Policy.can_upload?(board.id)
    assert modifier |> scope() |> Policy.can_upload?(board.id)
    refute reader |> scope() |> Policy.can_upload?(board.id)
    refute stranger |> scope() |> Policy.can_upload?(board.id)

    assert owner |> scope() |> Policy.can_read?(board.id)
    assert modifier |> scope() |> Policy.can_read?(board.id)
    assert reader |> scope() |> Policy.can_read?(board.id)
    refute stranger |> scope() |> Policy.can_read?(board.id)

    assert owner |> scope() |> Policy.can_delete?(board.id, by_modifier)
    assert owner |> scope() |> Policy.can_delete?(board.id, orphaned)
    assert modifier |> scope() |> Policy.can_delete?(board.id, by_modifier)
    refute modifier |> scope() |> Policy.can_delete?(board.id, by_reader)
    assert reader |> scope() |> Policy.can_delete?(board.id, by_reader)
    refute reader |> scope() |> Policy.can_delete?(board.id, orphaned)

    refute stranger
           |> scope()
           |> Policy.can_delete?(board.id, %TaskAttachment{
             uploaded_by_id: stranger.id
           })
  end

  test "resolve/2 separates members from non-members with one lookup", ctx do
    assert %{access: :owner, user_id: owner_id} =
             ctx.owner |> scope() |> Policy.resolve(ctx.board.id)

    assert owner_id == ctx.owner.id
    assert ctx.reader |> scope() |> Policy.resolve(ctx.board.id) |> Policy.member?()
    refute ctx.stranger |> scope() |> Policy.resolve(ctx.board.id) |> Policy.member?()
    assert Policy.resolve(nil, ctx.board.id) == %{user_id: nil, access: nil}
    assert Policy.resolve(%{user: nil}, ctx.board.id) == %{user_id: nil, access: nil}
    assert %{access: nil} = ctx.owner |> scope() |> Policy.resolve("#{ctx.board.id}")
  end

  test "a comment-level upload needs the upload right and authorship", ctx do
    comment = %TaskComment{author_user_id: ctx.modifier.id}

    may_upload_to = fn user, comment ->
      user
      |> scope()
      |> Policy.resolve(ctx.board.id)
      |> Policy.allowed?(:upload_to_comment, comment)
    end

    assert may_upload_to.(ctx.modifier, comment)
    refute may_upload_to.(ctx.owner, comment)
    refute may_upload_to.(ctx.reader, %TaskComment{author_user_id: ctx.reader.id})
    refute may_upload_to.(ctx.stranger, %TaskComment{author_user_id: ctx.stranger.id})
    refute may_upload_to.(ctx.modifier, %TaskComment{author_user_id: nil})
  end

  test "an uploader removed from the board can no longer delete their file", ctx do
    attachment = %TaskAttachment{uploaded_by_id: ctx.modifier.id}
    assert ctx.modifier |> scope() |> Policy.can_delete?(ctx.board.id, attachment)

    {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.modifier, ctx.owner)

    refute ctx.modifier |> scope() |> Policy.can_delete?(ctx.board.id, attachment)
    refute ctx.modifier |> scope() |> Policy.can_read?(ctx.board.id)
  end
end
