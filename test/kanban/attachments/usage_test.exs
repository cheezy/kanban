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

  test "a file counts where its task is now, not where it was uploaded" do
    user = user_fixture()
    organization = organization_fixture()
    org_board = user |> board_fixture() |> move_board_to_organization(organization)
    personal = board_fixture(user)
    task = board_task(personal)
    attachment_fixture(task, %{byte_size: 25})

    assert Usage.bytes_used({:board, personal.id}) == 25
    assert Usage.bytes_used({:organization, organization.id}) == 0

    {1, _} =
      Kanban.Tasks.Task
      |> Ecto.Query.where([t], t.id == ^task.id)
      |> Kanban.Repo.update_all(set: [column_id: column_fixture(org_board).id])

    assert Usage.bytes_used({:board, personal.id}) == 0
    assert Usage.bytes_used({:board, org_board.id}) == 25
    assert Usage.bytes_used({:organization, organization.id}) == 25
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

  test "lock_for_upload returns not_found when a referenced uploader, board or comment is gone" do
    organization = organization_fixture()
    owner = user_fixture()
    board = owner |> board_fixture() |> move_board_to_organization(organization)
    task = board_task(board)

    lock = fn refs -> Repo.transact(fn -> Usage.lock_for_upload(task.id, refs) end) end

    assert {:ok, {:organization, _id}} =
             Repo.transact(fn ->
               {:ok, scope} =
                 Usage.lock_for_upload(task.id, uploaded_by_id: owner.id, board_id: board.id)

               {:ok, scope}
             end)

    assert lock.(uploaded_by_id: -1) == {:error, :not_found}
    assert lock.(board_id: -1) == {:error, :not_found}
    assert lock.(comment_id: -1) == {:error, :not_found}
    assert {:ok, _scope} = lock.(uploaded_by_id: nil, board_id: nil, comment_id: nil)
  end

  describe "check_board_move/2" do
    setup do
      user = user_fixture()
      organization = organization_fixture()
      member_board = user |> board_fixture() |> move_board_to_organization(organization)
      attachment_fixture(board_task(member_board), %{byte_size: 60})
      %{user: user, organization: organization}
    end

    test "lets a board in when its files fit, up to the quota exactly", ctx do
      put_limits(organization_quota_bytes: 100)
      board = board_fixture(ctx.user)
      attachment_fixture(board_task(board), %{byte_size: 30})
      attachment_fixture(board_task(board), %{byte_size: 10})

      assert Usage.check_board_move(board.id, ctx.organization.id) == :ok
    end

    test "refuses a board one byte past the quota, naming its bytes, what is left and the shortfall",
         ctx do
      put_limits(organization_quota_bytes: 100)
      board = board_fixture(ctx.user)
      attachment_fixture(board_task(board), %{byte_size: 41})

      assert Usage.check_board_move(board.id, ctx.organization.id) ==
               {:error,
                {:quota_exceeded, %{board_bytes: 41, available_bytes: 40, shortfall_bytes: 1}}}
    end

    test "reports nothing left when the Organization is already over its quota", ctx do
      put_limits(organization_quota_bytes: 50)
      board = board_fixture(ctx.user)
      attachment_fixture(board_task(board), %{byte_size: 5})

      assert Usage.check_board_move(board.id, ctx.organization.id) ==
               {:error,
                {:quota_exceeded, %{board_bytes: 5, available_bytes: 0, shortfall_bytes: 15}}}
    end

    test "always lets in a board without files, even into an Organization over its quota", ctx do
      put_limits(organization_quota_bytes: 50)

      assert Usage.check_board_move(board_fixture(ctx.user).id, ctx.organization.id) == :ok
    end

    test "counts only the board's own files, not its owner's other personal boards", ctx do
      put_limits(organization_quota_bytes: 100)
      board = board_fixture(ctx.user)
      attachment_fixture(board_task(board), %{byte_size: 40})
      attachment_fixture(board_task(board_fixture(ctx.user)), %{byte_size: 1_000})

      assert Usage.check_board_move(board.id, ctx.organization.id) == :ok
    end

    test "holds the Organization's upload advisory lock until the transaction ends", ctx do
      board = board_fixture(ctx.user)
      organization_id = ctx.organization.id

      assert Usage.check_board_move(board.id, organization_id) == :ok

      %{rows: rows} =
        Kanban.Repo.query!(
          "SELECT classid::int, objid::int FROM pg_locks " <>
            "WHERE locktype = 'advisory' AND objsubid = 2 AND pid = pg_backend_pid()"
        )

      assert [41_001, organization_id] in rows
    end
  end

  describe "lock_quota/1" do
    defp advisory_locks do
      %{rows: rows} =
        Kanban.Repo.query!(
          "SELECT classid::int, objid::int FROM pg_locks " <>
            "WHERE locktype = 'advisory' AND objsubid = 2 AND pid = pg_backend_pid()"
        )

      rows
    end

    test "takes the same advisory lock an upload into the scope takes" do
      organization_id = organization_fixture().id
      board_id = board_fixture(user_fixture()).id

      assert Usage.lock_quota({:organization, organization_id}) == :ok
      assert Usage.lock_quota({:board, board_id}) == :ok

      assert [41_001, organization_id] in advisory_locks()
      assert [41_002, board_id] in advisory_locks()
    end
  end
end
