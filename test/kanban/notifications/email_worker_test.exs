defmodule Kanban.Notifications.EmailWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Boards
  alias Kanban.Notifications
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification

  defp board_with_member do
    owner = user_fixture()
    member = user_fixture()
    board = board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    %{owner: owner, member: member, board: board}
  end

  # user_fixture/1 sends an account-confirmation email to the test process;
  # drop those so the assertions below only see notification emails.
  defp run_job(notification) do
    flush_emails()
    perform_job(EmailWorker, %{notification_id: notification.id})
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  describe "enqueueing from notify/3" do
    test "enqueues one job for a recipient whose email preference is on by default" do
      user = user_fixture()
      n = notification_fixture(user)

      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id}, queue: :notifications)
    end

    test "enqueues nothing when the recipient turned email off" do
      user = user_fixture()
      preference_fixture(user, :board_access_changed, %{in_app: true, email: false})

      n = notification_fixture(user)

      refute_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "honours a saved email preference over a default that is off" do
      user = user_fixture()
      board = board_fixture(user)
      preference_fixture(user, :goal_completed, %{in_app: true, email: true})

      {:ok, [n]} =
        Notifications.notify(:goal_completed, [user], %{title: "G1 done", board_id: board.id})

      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "enqueues nothing for an event type whose email default is off" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, [n]} =
        Notifications.notify(:goal_completed, [user], %{title: "G1 done", board_id: board.id})

      refute_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "enqueues exactly one job per opted-in recipient" do
      %{owner: owner, member: member, board: board} = board_with_member()
      preference_fixture(owner, :review_requested, %{in_app: true, email: false})

      {:ok, [_, _]} =
        Notifications.notify(:review_requested, [owner, member], %{
          title: "Review",
          board_id: board.id
        })

      assert [%Oban.Job{args: %{"notification_id" => id}}] = all_enqueued(worker: EmailWorker)
      assert Repo.get!(Notification, id).user_id == member.id
    end

    test "a repeated dedupe key enqueues no second job" do
      user = user_fixture()
      attrs = %{title: "Once", dedupe_key: "board_access_changed:1"}

      {:ok, [_]} = Notifications.notify(:board_access_changed, [user], attrs)
      {:ok, []} = Notifications.notify(:board_access_changed, [user], attrs)

      assert length(all_enqueued(worker: EmailWorker)) == 1
    end

    test "a rolled-back notification leaves no job behind" do
      user = user_fixture()

      assert {:error, :boom} =
               Repo.transaction(fn ->
                 {:ok, [_]} = Notifications.notify(:board_access_changed, [user], %{title: "x"})
                 Repo.rollback(:boom)
               end)

      refute_enqueued(worker: EmailWorker)
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "invalid attributes enqueue nothing" do
      user = user_fixture()

      assert {:error, _} =
               Notifications.notify(:board_access_changed, [user], %{body: "no title"})

      refute_enqueued(worker: EmailWorker)
    end

    test "enqueues a job for a recipient with in-app off but email on" do
      user = user_fixture()
      preference_fixture(user, :board_access_changed, %{in_app: false, email: true})

      {:ok, [n]} = Notifications.notify(:board_access_changed, [user], %{title: "x"})

      refute n.in_app
      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "enqueue/1 is unique per notification" do
      user = user_fixture()
      preference_fixture(user, :board_access_changed, %{in_app: true, email: false})
      n = notification_fixture(user)

      assert all_enqueued(worker: EmailWorker) == []
      assert :ok = EmailWorker.enqueue([n])
      assert :ok = EmailWorker.enqueue([n])

      assert length(all_enqueued(worker: EmailWorker)) == 1
    end

    test "enqueue/1 with no notifications is a no-op" do
      assert :ok = EmailWorker.enqueue([])
      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "perform/1" do
    test "delivers one email with both bodies and unsubscribe headers, then stamps emailed_at" do
      user = user_fixture()
      n = notification_fixture(user, %{title: "Removed from Alpha"})

      assert :ok = run_job(n)

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == "[Stride] Your board access changed"
        assert email.html_body =~ "Removed from Alpha"
        assert email.text_body =~ "Removed from Alpha"
        assert email.headers["List-Unsubscribe"] =~ "/notifications/unsubscribe/one-click?token="
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      end)

      assert %DateTime{} = Repo.reload!(n).emailed_at
    end

    test "a second perform for the same notification sends nothing" do
      user = user_fixture()
      n = notification_fixture(user)

      assert :ok = run_job(n)
      assert_email_sent()

      assert :ok = run_job(n)
      refute_email_sent()
    end

    test "uses the recipient's current email address" do
      user = user_fixture()
      n = notification_fixture(user)
      new_email = unique_user_email()
      user |> Ecto.Changeset.change(email: new_email) |> Repo.update!()

      assert :ok = run_job(n)
      assert_email_sent(to: new_email)
    end

    test "preloads the board for board-scoped notifications" do
      %{member: member, board: board} = board_with_member()

      {:ok, [n]} =
        Notifications.notify(:review_requested, [member], %{title: "Review", board_id: board.id})

      assert :ok = run_job(n)
      assert_email_sent(fn email -> assert email.text_body =~ board.name end)
    end

    test "returns :ok without sending when the notification is gone" do
      user = user_fixture()
      n = notification_fixture(user)
      Repo.delete!(n)

      assert :ok = run_job(n)
      refute_email_sent()
    end

    test "returns :ok without sending to a disabled user" do
      user = user_fixture()
      n = notification_fixture(user)

      user
      |> Ecto.Changeset.change(disabled_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update!()

      assert :ok = run_job(n)
      refute_email_sent()
      assert is_nil(Repo.reload!(n).emailed_at)
    end

    test "emails an in-app-off recipient whose email preference is on" do
      user = user_fixture()
      preference_fixture(user, :board_access_changed, %{in_app: false, email: true})
      {:ok, [n]} = Notifications.notify(:board_access_changed, [user], %{title: "Email only"})

      assert :ok = run_job(n)
      assert_email_sent(fn email -> assert email.text_body =~ "Email only" end)
    end

    test "returns :ok without sending to an unconfirmed user" do
      user = unconfirmed_user_fixture()
      n = notification_fixture(user)

      assert :ok = run_job(n)
      refute_email_sent()
    end

    test "returns :ok without sending to a user who left the notification's board" do
      %{owner: owner, member: member, board: board} = board_with_member()

      {:ok, [n]} =
        Notifications.notify(:review_requested, [member], %{title: "Review", board_id: board.id})

      {:ok, _} = Boards.remove_user_from_board(board, member, owner)

      assert :ok = run_job(n)
      refute_email_sent()
    end
  end

  describe "failure_kind/1" do
    test "maps mailer errors to bounded kinds without the raw reason" do
      assert EmailWorker.failure_kind({:permanent_failure, "h", "550 <a@b>"}) ==
               :permanent_failure

      assert EmailWorker.failure_kind({:temporary_failure, "h", "421"}) == :temporary_failure
      assert EmailWorker.failure_kind({:retries_exceeded, :timeout}) == :retries_exceeded
      assert EmailWorker.failure_kind(:econnrefused) == :delivery_failed
    end
  end
end
