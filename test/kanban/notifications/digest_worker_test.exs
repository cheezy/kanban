defmodule Kanban.Notifications.DigestWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.TasksFixtures
  import Swoosh.TestAssertions

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.DigestFanoutWorker
  alias Kanban.Notifications.DigestWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks.Task

  @now "2026-11-02T13:00:00Z"
  @week "2026-W45"

  # user_fixture/1 sends an account-confirmation email to the test process;
  # drop those so the assertions below only see digest emails.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp active_user do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    done = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Done"))
    task = task_fixture(done)

    Task
    |> where(id: ^task.id)
    |> Repo.update_all(set: [completed_at: ~U[2026-10-30 10:00:00Z]])

    flush_emails()
    %{user: user, board: board}
  end

  defp disable(user) do
    User
    |> where(id: ^user.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
  end

  defp run_digest(user, week \\ @week) do
    perform_job(DigestWorker, %{user_id: user.id, week: week, now: @now})
  end

  defp digest_rows(user) do
    Notification
    |> where(user_id: ^user.id, event_type: :weekly_digest)
    |> Repo.all()
  end

  defp enqueued_user_ids do
    [worker: DigestWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args["user_id"])
    |> Enum.sort()
  end

  describe "cron configuration" do
    test "runs the fan-out on Mondays at 13:00 UTC" do
      {Oban.Plugins.Cron, opts} =
        :kanban
        |> Application.fetch_env!(Oban)
        |> Keyword.fetch!(:plugins)
        |> List.keyfind(Oban.Plugins.Cron, 0)

      assert {"0 13 * * 1", DigestFanoutWorker} in Keyword.fetch!(opts, :crontab)
    end
  end

  describe "DigestFanoutWorker" do
    test "enqueues one job per opted-in, confirmed, enabled board member" do
      by_default = user_fixture()
      board_fixture(by_default)
      opted_in = user_fixture()
      board_fixture(opted_in)
      preference_fixture(opted_in, :weekly_digest, %{in_app: true, email: true})
      owner = user_fixture()
      reader = user_fixture()
      {:ok, _} = owner |> board_fixture() |> Boards.add_user_to_board(reader, :read_only, owner)

      opted_out = user_fixture()
      board_fixture(opted_out)
      preference_fixture(opted_out, :weekly_digest, %{in_app: true, email: false})
      board_fixture(unconfirmed_user_fixture())
      disabled = user_fixture()
      board_fixture(disabled)
      disable(disabled)
      _no_boards = user_fixture()

      assert :ok = perform_job(DigestFanoutWorker, %{"now" => @now})

      assert enqueued_user_ids() == Enum.sort([by_default.id, opted_in.id, owner.id, reader.id])

      assert_enqueued(
        worker: DigestWorker,
        queue: :notifications,
        args: %{user_id: reader.id, week: @week, now: @now}
      )
    end

    test "tags jobs with the ISO week of now, including week 53" do
      %{user: user} = active_user()

      assert :ok = perform_job(DigestFanoutWorker, %{"now" => "2027-01-01T13:00:00Z"})

      assert_enqueued(worker: DigestWorker, args: %{user_id: user.id, week: "2026-W53"})
    end

    test "running twice in the same week enqueues one job per user" do
      %{user: user} = active_user()

      assert :ok = perform_job(DigestFanoutWorker, %{"now" => @now})
      assert :ok = perform_job(DigestFanoutWorker, %{"now" => "2026-11-02T14:00:00Z"})

      assert enqueued_user_ids() == [user.id]
    end

    test "skips a user who unsubscribed from the digest" do
      %{user: user} = active_user()
      :ok = Notifications.unsubscribe(user.id, :weekly_digest)

      assert :ok = perform_job(DigestFanoutWorker, %{})

      refute_enqueued(worker: DigestWorker, args: %{user_id: user.id})
    end
  end

  describe "DigestWorker" do
    test "sends one digest email and records it without an inbox entry" do
      %{user: user, board: board} = active_user()

      assert :ok = run_digest(user)

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == "[Stride] Your weekly digest"
        assert email.html_body =~ "/boards/#{board.id}"
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
        assert email.headers["List-Unsubscribe"] =~ "/notifications/unsubscribe/one-click?token="
      end)

      assert [row] = digest_rows(user)
      assert row.dedupe_key == "weekly_digest:#{@week}"
      assert row.in_app == false
      assert row.emailed_at
      assert row.metadata == %{"week" => @week}
      assert user |> Scope.for_user() |> Notifications.unread_count() == 0
    end

    test "a second run for the same week sends nothing; another week sends again" do
      %{user: user} = active_user()

      assert :ok = run_digest(user)
      assert_email_sent(subject: "[Stride] Your weekly digest")

      assert :ok = run_digest(user)
      assert_no_email_sent()
      assert length(digest_rows(user)) == 1

      assert :ok = run_digest(user, "2026-W46")
      assert_email_sent(subject: "[Stride] Your weekly digest")
      assert length(digest_rows(user)) == 2
    end

    test "jobs are unique per user and week" do
      %{user: user} = active_user()
      args = %{user_id: user.id, week: @week, now: @now}

      assert {:ok, %Oban.Job{conflict?: false}} = args |> DigestWorker.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true}} =
               %{args | now: "2026-11-02T14:00:00Z"} |> DigestWorker.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: false}} =
               %{args | week: "2026-W46"} |> DigestWorker.new() |> Oban.insert()
    end

    test "sends nothing and records nothing for a quiet week" do
      user = user_fixture()
      board_fixture(user)
      flush_emails()

      assert :ok = run_digest(user)

      assert_no_email_sent()
      assert digest_rows(user) == []
    end

    test "sends nothing to a user disabled or opted out after the fan-out" do
      %{user: disabled} = active_user()
      disable(disabled)
      %{user: opted_out} = active_user()
      :ok = Notifications.unsubscribe(opted_out.id, :weekly_digest)

      assert :ok = run_digest(disabled)
      assert :ok = run_digest(opted_out)

      assert_no_email_sent()
      assert digest_rows(disabled) == []
      assert digest_rows(opted_out) == []
    end

    test "sends nothing when the user's only board was deleted after the fan-out" do
      %{user: user, board: board} = active_user()
      {:ok, _} = Boards.delete_board(board, user)

      assert :ok = run_digest(user)

      assert_no_email_sent()
      assert digest_rows(user) == []
    end

    test "returns an error for Oban to retry when the record cannot be written" do
      %{user: user} = active_user()
      week = String.duplicate("W", 300)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, :record_failed} = run_digest(user, week)
        end)

      assert log =~ "user_id=#{user.id}"
      refute log =~ user.email
      assert_no_email_sent()
      assert digest_rows(user) == []
    end

    test "sends nothing for a user who no longer exists" do
      assert :ok = perform_job(DigestWorker, %{user_id: -1, week: @week, now: @now})
      assert_no_email_sent()
    end
  end
end
