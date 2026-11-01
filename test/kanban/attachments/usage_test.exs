defmodule Kanban.Attachments.UsageTest do
  # Not async: some tests change the application-wide attachment limits.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Usage

  setup do
    previous = Application.get_env(:kanban, Limits)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:kanban, Limits)
  defp restore(previous), do: Application.put_env(:kanban, Limits, previous)

  defp put_limits(limits) do
    Application.put_env(
      :kanban,
      Limits,
      Keyword.merge(Application.get_env(:kanban, Limits, []), limits)
    )
  end

  defp board_task(board), do: board |> column_fixture() |> task_fixture()

  test "sums bytes across every board of an Organization" do
    user = user_fixture()
    organization = organization_fixture()
    first = user |> board_fixture() |> move_board_to_organization(organization)
    second = user |> board_fixture() |> move_board_to_organization(organization)
    outside = board_fixture(user)

    attachment_fixture(board_task(first), %{byte_size: 100})
    attachment_fixture(board_task(first), %{byte_size: 20})
    attachment_fixture(board_task(second), %{byte_size: 3})
    attachment_fixture(board_task(outside), %{byte_size: 4_000})

    assert Usage.quota_scope(first.id) == {:organization, organization.id}
    assert Usage.quota_scope(second.id) == {:organization, organization.id}
    assert Usage.bytes_used({:organization, organization.id}) === 123
    assert Usage.bytes_used({:organization, organization_fixture().id}) === 0
  end

  test "counts a board outside an Organization on its own" do
    user = user_fixture()
    personal = board_fixture(user)
    other = board_fixture(user)

    attachment_fixture(board_task(personal), %{byte_size: 7})
    attachment_fixture(board_task(personal), %{byte_size: 2})
    attachment_fixture(board_task(other), %{byte_size: 50})

    assert Usage.quota_scope(personal.id) == {:board, personal.id}
    assert Usage.quota_scope(other.id) == {:board, other.id}
    assert Usage.bytes_used({:board, personal.id}) === 9
    assert Usage.bytes_used({:board, other.id}) === 50
    assert Usage.bytes_used({:board, board_fixture(user).id}) === 0
  end

  test "count_for_task counts task-level and comment-level files on that task only" do
    board = board_fixture(user_fixture())
    task = board_task(board)
    attachment_fixture(task)
    attachment_fixture(task)
    attachment_fixture(board_task(board))

    assert Usage.count_for_task(task.id) == 2
    assert Usage.count_for_task(board_task(board).id) == 0
  end

  test "check_limits refuses at the file count and above the quota, inclusive of the edge" do
    board = board_fixture(user_fixture())
    task = board_task(board)
    scope = Usage.quota_scope(board.id)
    put_limits(max_files_per_task: 2, organization_quota_bytes: 100)

    attachment_fixture(task, %{byte_size: 60})
    assert Usage.check_limits(task.id, scope, 40) == :ok
    assert Usage.check_limits(task.id, scope, 41) == {:error, :quota_exceeded}

    attachment_fixture(task, %{byte_size: 40})
    assert Usage.check_limits(task.id, scope, 1) == {:error, :too_many_files}
    assert Usage.check_limits(board_task(board).id, scope, 1) == {:error, :quota_exceeded}
  end

  test "lock_for_upload returns the quota scope inside a transaction, and not_found for a missing task" do
    organization = organization_fixture()
    board = user_fixture() |> board_fixture() |> move_board_to_organization(organization)
    task = board_task(board)

    assert {:ok, {:ok, {:organization, id}}} =
             Repo.transact(fn -> {:ok, Usage.lock_for_upload(task.id)} end)

    assert id == organization.id
    assert Repo.transact(fn -> Usage.lock_for_upload(-1) end) == {:error, :not_found}
  end
end
