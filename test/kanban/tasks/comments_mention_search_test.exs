defmodule Kanban.Tasks.CommentsMentionSearchTest do
  @moduledoc """
  Unit tests for `Kanban.Tasks.Comments.search_mentionable_members/4`, the
  board-scoped member search behind the comment `@mention` autocomplete.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Comments
  alias Kanban.Tasks.Mentions
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    task = board |> column_fixture() |> task_fixture()
    %{owner: owner, board: board, task: task}
  end

  defp add_member(board, owner, name) do
    member = user_fixture()

    {:ok, member} =
      if name, do: Accounts.update_user_name(member, %{name: name}), else: {:ok, member}

    {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    member
  end

  defp search(user, task, query, limit \\ 8),
    do: Comments.search_mentionable_members(user && Scope.for_user(user), task, query, limit)

  test "returns members of the task's board whose name matches the query",
       %{owner: owner, board: board, task: task} do
    grace = add_member(board, owner, "Grace Hopper")
    add_member(board, owner, "Alan Turing")

    assert {:ok, [%{id: id, label: "Grace Hopper"}]} = search(owner, task, "hop")
    assert id == grace.id
  end

  test "labels a member with no name by email and never returns the email field",
       %{owner: owner, board: board, task: task} do
    nameless = add_member(board, owner, nil)

    assert {:ok, [member]} = search(owner, task, nameless.email)
    assert member == %{id: nameless.id, label: nameless.email}
  end

  test "falls back to the email when the name is only whitespace",
       %{owner: owner, board: board, task: task} do
    blank = add_member(board, owner, nil)
    from(u in Accounts.User, where: u.id == ^blank.id) |> Repo.update_all(set: [name: " \n "])

    assert {:ok, [member]} = search(owner, task, blank.email)
    assert member == %{id: blank.id, label: blank.email}
  end

  test "makes every label safe to place in a mention token",
       %{owner: owner, board: board, task: task} do
    member = add_member(board, owner, "Evil@[x](user:1)")

    assert {:ok, [%{id: id, label: label}]} = search(owner, task, "Evil")
    assert id == member.id
    assert Mentions.parse("@[#{label}](user:#{id})") == [id]
  end

  test "returns at most limit members", %{owner: owner, board: board, task: task} do
    for n <- 1..10, do: add_member(board, owner, "Member #{n}")

    assert {:ok, members} = search(owner, task, "Member", 8)
    assert length(members) == 8
  end

  test "searches only the task's own board", %{owner: owner, board: board, task: task} do
    other_owner = user_fixture()
    other_board = board_fixture(other_owner)
    add_member(other_board, other_owner, "Grace Elsewhere")
    add_member(board, owner, "Grace Here")

    assert {:ok, [%{label: "Grace Here"}]} = search(owner, task, "Grace")
  end

  test "refuses a viewer who is not a member of the task's board", %{task: task} do
    assert search(user_fixture(), task, "") == {:error, :unauthorized}
    assert search(nil, task, "") == {:error, :unauthorized}
  end

  test "returns :not_found for an unsaved or deleted task", %{owner: owner, task: task} do
    assert search(owner, %Task{}, "") == {:error, :not_found}

    Repo.delete!(task)
    assert search(owner, task, "") == {:error, :not_found}
  end

  test "is exposed through the Tasks facade", %{owner: owner, task: task} do
    assert {:ok, [%{id: id}]} =
             owner |> Scope.for_user() |> Tasks.search_mentionable_members(task, "", 8)

    assert id == owner.id
  end
end
