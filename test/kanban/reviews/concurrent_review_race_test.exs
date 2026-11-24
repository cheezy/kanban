defmodule Kanban.Reviews.ConcurrentReviewRaceTest do
  @moduledoc """
  Proves that two reviewers approving the same task at once commit one
  approval and one `:review_approved` audit row, with real, committing
  connections.

  The sandboxed `Kanban.ReviewsTest` cannot show it: every process there
  shares one transaction, so two approvals never overlap. Here the test holds
  the task's row lock, starts two approvals on their own connections, waits
  until both are blocked on that lock, and then lets them go. Without the
  `FOR UPDATE` lock `Kanban.Reviews` takes before it re-reads the pending
  task, both approvals have already read it as pending by then, so both
  commit and two audit rows are written.

  It also proves that a signed phone approval re-checks what the reviewer was
  shown under that lock: an edit committed while the approval waits on the
  row lock changes the task's review fingerprint, so the approval is refused.

  ## Running

  These tests carry `@moduletag :review_race`, which `test/test_helper.exs`
  excludes, so the normal suite never runs them. Their audit rows commit, and
  the append-only trigger on `audit_events` refuses to delete them, so they
  run only in a throwaway database, dropped before and after the run:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only review_race test/kanban/reviews/concurrent_review_race_test.exs
      dropdb kanban_test_race

  `setup_all` refuses any database whose name does not end in `_race`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TasksFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Reviews.Approval
  alias Kanban.Reviews.ApprovalChallenge
  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @moduletag :review_race
  @moduletag timeout: 120_000

  @deadline_ms 30_000

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits audit events that can never be deleted, so it \
      runs only in the throwaway kanban_test_race database, not #{database}:

          dropdb --if-exists kanban_test_race
          MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only review_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Review", position: 1})
    _done = column_fixture(board, %{name: "Done", position: 2})

    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        needs_review: true,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        completed_by_agent: "Claude"
      })

    %{user: user, task: task}
  end

  test "two approvals at once commit one approval and one audit row",
       %{user: user, task: task} do
    {:ok, results} =
      Repo.transaction(fn ->
        Repo.one!(from(t in Task, where: t.id == ^task.id, lock: "FOR UPDATE", select: t.id))

        approvals = for _ <- 1..2, do: Elixir.Task.async(fn -> approve(user, task) end)
        await_blocked_on_lock(2)
        approvals
      end)

    outcomes = Enum.map(results, &Elixir.Task.await(&1, @deadline_ms))

    assert [{:ok, _approved}] = Enum.filter(outcomes, &match?({:ok, _}, &1))
    assert [{:error, _refused}] = Enum.reject(outcomes, &match?({:ok, _}, &1))

    assert [_one] =
             [action: :review_approved]
             |> AuditLog.list_events(order: :asc)
             |> Enum.filter(&(&1.metadata["task_id"] == task.id))
  end

  test "edit during approval refuses it", %{user: user, task: task} do
    scope = Scope.for_user(user)
    key = approval_keypair_fixture()
    phone = device_fixture(scope, %{device_class: :phone, approval_public_key: key.public_key})
    requested_at = DateTime.utc_now() |> DateTime.truncate(:second)

    task =
      task
      |> Ecto.Changeset.change(review_requested_at: requested_at, acceptance_criteria: "It works")
      |> Repo.update!()

    shown = %{"review_fingerprint" => ApprovalChallenge.review_fingerprint(task)}
    {:ok, challenge, _task} = Approval.issue_challenge(scope, phone, task.id, shown)

    params = %{
      "review_requested_at" => Approval.stamp(requested_at),
      "nonce" => challenge.nonce,
      "signature" =>
        sign_approval(
          key.private_key,
          Approval.signing_string(challenge.nonce, task.id, requested_at)
        )
    }

    {:ok, approval} =
      Repo.transaction(fn ->
        Repo.one!(from(t in Task, where: t.id == ^task.id, lock: "FOR UPDATE", select: t.id))

        approval =
          Elixir.Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)
            Approval.approve(scope, phone, task.id, params)
          end)

        await_blocked_on_lock(1)

        # Committed with the lock released, after the approval's first read.
        Task
        |> where([t], t.id == ^task.id)
        |> Repo.update_all(set: [acceptance_criteria: "It works\nAnd it ships unreviewed"])

        approval
      end)

    assert {:error, {:signature_rejected, :invalid}} = Elixir.Task.await(approval, @deadline_ms)
    assert Repo.get!(Task, task.id).review_status in [nil, :pending]
    assert Repo.get!(ApprovalChallenge, challenge.id).used_at == nil
  end

  defp approve(user, task) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user |> Scope.for_user() |> Reviews.approve_review(task, via: :web)
  end

  # Polls until `count` other backends of this database wait on a lock, so
  # both approvals are past whatever they read before they block.
  defp await_blocked_on_lock(count, waited \\ 0) do
    blocked =
      from(a in fragment("pg_stat_activity"),
        where:
          a.datname == fragment("current_database()") and a.wait_event_type == "Lock" and
            a.pid != fragment("pg_backend_pid()"),
        select: count()
      )
      |> Repo.one!()

    cond do
      blocked >= count ->
        :ok

      waited >= @deadline_ms ->
        flunk("only #{blocked} of #{count} approvals blocked on the task's row lock")

      true ->
        Process.sleep(20)
        await_blocked_on_lock(count, waited + 20)
    end
  end
end
