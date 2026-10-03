defmodule Kanban.Notifications.DigestWorkerFailureTest do
  # Swaps the global mailer adapter, so it cannot run concurrently.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures
  import Swoosh.TestAssertions

  alias Kanban.Columns
  alias Kanban.Notifications.DigestWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks.Task

  @args %{week: "2026-W45", now: "2026-11-02T13:00:00Z"}

  setup do
    original = Application.get_env(:kanban, Kanban.Mailer)
    on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)

    user = user_fixture()
    board = ai_optimized_board_fixture(user, %{name: "Private board name"})
    done = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Done"))
    task = task_fixture(done)

    Task
    |> where(id: ^task.id)
    |> Repo.update_all(set: [completed_at: ~U[2026-10-30 10:00:00Z]])

    flush_emails()
    %{user: user, original: original}
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp rows(user) do
    Notification
    |> where(user_id: ^user.id, event_type: :weekly_digest)
    |> Repo.all()
  end

  test "a failed delivery returns an error, keeps no record and logs no private data",
       %{user: user} do
    Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
    args = Map.put(@args, :user_id, user.id)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :retries_exceeded} = perform_job(DigestWorker, args)
      end)

    assert rows(user) == []
    assert log =~ "user_id=#{user.id}"
    assert log =~ "retries_exceeded"
    refute log =~ user.email
    refute log =~ "Private board name"
    refute log =~ "smtp.gmail.com"
  end

  test "the retry after a failure sends exactly one email", %{user: user, original: original} do
    Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
    args = Map.put(@args, :user_id, user.id)

    capture_log(fn -> assert {:error, _kind} = perform_job(DigestWorker, args) end)

    Application.put_env(:kanban, Kanban.Mailer, original)

    assert :ok = perform_job(DigestWorker, args)
    assert_email_sent(subject: "[Stride] Your weekly digest")
    assert :ok = perform_job(DigestWorker, args)
    assert_no_email_sent()
    assert [%Notification{emailed_at: %DateTime{}}] = rows(user)
  end
end
