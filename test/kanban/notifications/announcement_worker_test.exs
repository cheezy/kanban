defmodule Kanban.Notifications.AnnouncementWorkerTest do
  # async: false — one test swaps the global mailer adapter.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers
  import Swoosh.TestAssertions

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Notifications.Announcement
  alias Kanban.Notifications.AnnouncementWorker

  @key "organizations-launch"
  @english_subject "[Stride] Announcing Organizations and the Free plan"

  defmodule OneFailingMailbox do
    @moduledoc false
    # Fails delivery to the one address the test names; every other email
    # goes to Swoosh's test adapter as usual.
    use Swoosh.Adapter

    @impl true
    def deliver(%Swoosh.Email{to: [{_name, address}]} = email, config) do
      if address == Application.get_env(:kanban, :announcement_failing_address),
        do: {:error, {:permanent_failure, ~c"mx.example.test", "550 no such mailbox"}},
        else: Swoosh.Adapters.Test.deliver(email, config)
    end
  end

  # user_fixture/1 sends an account-confirmation email to the test process;
  # drop those so the assertions below only see announcement emails.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp disable(user) do
    User
    |> where(id: ^user.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
  end

  defp args(user), do: %{user_id: user.id, key: @key}

  describe "fan_out/2" do
    test "selects confirmed, enabled users and skips disabled and unconfirmed ones" do
      active = user_fixture()
      disabled = user_fixture()
      disable(disabled)
      unconfirmed = unconfirmed_user_fixture()

      recipients = Announcement.list_recipients()

      assert active.id in recipients
      refute disabled.id in recipients
      refute unconfirmed.id in recipients
      assert Announcement.get_recipient(active.id).id == active.id
      assert Announcement.get_recipient(disabled.id) == nil
      assert Announcement.get_recipient(unconfirmed.id) == nil
    end

    test "a dry run returns the recipient count and enqueues nothing" do
      user_fixture()
      user_fixture()
      attach_telemetry([:kanban, :announcement, :fanout_completed])

      assert {:ok, result} = Announcement.fan_out(@key, dry_run: true)

      assert result == %{
               announcement: @key,
               dry_run: true,
               recipients: length(Announcement.list_recipients()),
               enqueued: 0,
               already_enqueued: 0,
               unconfirmed: 0
             }

      assert result.recipients >= 2
      assert all_enqueued(worker: AnnouncementWorker) == []
      refute_received {:telemetry_event, [:kanban, :announcement, :fanout_completed], _, _}
    end

    test "enqueues one unique job per recipient, and a second run adds none" do
      user = user_fixture()
      disabled = user_fixture()
      disable(disabled)
      attach_telemetry([:kanban, :announcement, :fanout_completed])

      assert {:ok, first} = Announcement.fan_out(@key)
      recipients = length(Announcement.list_recipients())

      assert %{dry_run: false, recipients: ^recipients, enqueued: ^recipients} = first
      assert first.already_enqueued == 0
      assert_enqueued(worker: AnnouncementWorker, args: %{user_id: user.id, key: @key})
      refute_enqueued(worker: AnnouncementWorker, args: %{user_id: disabled.id, key: @key})
      assert length(all_enqueued(worker: AnnouncementWorker)) == recipients

      assert_received {:telemetry_event, [:kanban, :announcement, :fanout_completed],
                       %{count: ^recipients}, %{announcement: @key} = metadata}

      refute inspect(metadata) =~ user.email

      assert {:ok, second} = Announcement.fan_out(@key)
      assert %{enqueued: 0, already_enqueued: ^recipients} = second
      assert length(all_enqueued(worker: AnnouncementWorker)) == recipients

      assert_received {:telemetry_event, [:kanban, :announcement, :fanout_completed], %{count: 0},
                       %{announcement: @key}}
    end

    test "a dry_run other than true or false raises and enqueues nothing" do
      user_fixture()

      for value <- ["true", 1, :yes, nil] do
        assert_raise ArgumentError, ~r/expected :dry_run to be true or false/, fn ->
          Announcement.fan_out(@key, dry_run: value)
        end
      end

      assert all_enqueued(worker: AnnouncementWorker) == []
    end

    test "a re-run sends nothing to a recipient whose job was cancelled or discarded" do
      cancelled = user_fixture()
      discarded = user_fixture()
      assert {:ok, %{enqueued: recipients}} = Announcement.fan_out(@key)

      for {user, state} <- [{cancelled, "cancelled"}, {discarded, "discarded"}] do
        Oban.Job
        |> where([j], j.args["user_id"] == ^user.id)
        |> Repo.update_all(set: [state: state])
      end

      assert {:ok, %{enqueued: 0, already_enqueued: ^recipients, unconfirmed: 0}} =
               Announcement.fan_out(@key)

      for user <- [cancelled, discarded] do
        assert [_one] = Oban.Job |> where([j], j.args["user_id"] == ^user.id) |> Repo.all()
      end
    end

    test "refuses an unknown key and enqueues nothing" do
      user_fixture()

      assert Announcement.fan_out("no-such-announcement") == {:error, :unknown_announcement}
      assert Announcement.fan_out(nil, dry_run: true) == {:error, :unknown_announcement}
      assert all_enqueued(worker: AnnouncementWorker) == []
    end
  end

  describe "await_enqueue/2" do
    # A unique insert that cannot take Oban's lock, because another run holds
    # it for the same recipient, returns a conflict with no id.
    @locked %Oban.Job{conflict?: true, id: nil}

    defp inserts(results) do
      {:ok, agent} = Agent.start_link(fn -> results end)

      fn ->
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)
      end
    end

    defp await(results, attempts \\ 5),
      do: results |> inserts() |> Announcement.await_enqueue(attempts)

    test "a new job is enqueued and an existing one is already enqueued" do
      assert await([%Oban.Job{conflict?: false, id: 1}]) == :enqueued
      assert await([%Oban.Job{conflict?: true, id: 7}]) == :already_enqueued
    end

    test "a job another run is inserting is tried again rather than counted as covered" do
      assert await([@locked, @locked, %Oban.Job{conflict?: false}]) == :enqueued
      assert await([@locked, %Oban.Job{conflict?: true, id: 3}]) == :already_enqueued
    end

    test "a job still held after every attempt is unconfirmed, never already enqueued" do
      assert await([@locked], 3) == :unconfirmed
    end
  end

  describe "perform/1" do
    test "sends one English email to a user with no stored locale and emits email_sent" do
      user = user_fixture()
      flush_emails()
      attach_telemetry([:kanban, :announcement, :email_sent])

      assert :ok = perform_job(AnnouncementWorker, args(user))

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == @english_subject
        assert email.text_body =~ "/changelog"
        assert email.text_body =~ "/pricing"
        assert email.text_body =~ "/terms"
      end)

      assert_received {:telemetry_event, [:kanban, :announcement, :email_sent], %{count: 1},
                       metadata}

      assert metadata == %{user_id: user.id, announcement: @key}
      refute inspect(metadata) =~ user.email
    end

    test "renders the email in the user's stored locale" do
      {:ok, user} = Accounts.update_user_locale(user_fixture(), "fr")
      flush_emails()

      assert :ok = perform_job(AnnouncementWorker, args(user))

      assert_email_sent(fn email ->
        assert email.subject == "[Stride] Annonce : les organisations et l'offre gratuite"
        assert email.text_body =~ "Lire le journal des modifications"
      end)
    end

    test "falls back to English for a stored locale the app no longer supports" do
      user = user_fixture()

      User
      |> where(id: ^user.id)
      |> Repo.update_all(set: [locale: "xx"])

      flush_emails()

      assert :ok = perform_job(AnnouncementWorker, args(user))
      assert_email_sent(subject: @english_subject)
      assert AnnouncementWorker.locale_for(%User{locale: "xx"}) == "en"
      assert AnnouncementWorker.locale_for(%User{locale: nil}) == "en"
      assert AnnouncementWorker.locale_for(%User{locale: "ja"}) == "ja"
    end

    test "skips a user disabled between the fan-out and the send" do
      user = user_fixture()
      {:ok, _result} = Announcement.fan_out(@key)
      disable(user)
      flush_emails()
      attach_telemetry([:kanban, :announcement, :email_sent])

      assert :ok = perform_job(AnnouncementWorker, args(user))
      assert_no_email_sent()
      refute_received {:telemetry_event, [:kanban, :announcement, :email_sent], _, _}
    end

    test "skips a job for an announcement key that has no email" do
      user = user_fixture()
      flush_emails()

      assert :ok = perform_job(AnnouncementWorker, %{user_id: user.id, key: "retired-key"})
      assert_no_email_sent()
    end
  end

  describe "a failing mailbox" do
    setup do
      original = Application.get_env(:kanban, Kanban.Mailer)

      on_exit(fn ->
        Application.put_env(:kanban, Kanban.Mailer, original)
        Application.delete_env(:kanban, :announcement_failing_address)
      end)

      Application.put_env(:kanban, Kanban.Mailer, adapter: OneFailingMailbox)
      :ok
    end

    test "fails only its own job, logs no address, and the other recipients still get theirs" do
      failing = user_fixture()
      other = user_fixture()
      Application.put_env(:kanban, :announcement_failing_address, failing.email)
      {:ok, _result} = Announcement.fan_out(@key)
      flush_emails()
      attach_telemetry([:kanban, :announcement, :email_sent])

      log =
        capture_log([level: :warning], fn ->
          assert %{failure: 1, success: success} = Oban.drain_queue(queue: :notifications)
          assert success == length(Announcement.list_recipients()) - 1
        end)

      assert log =~ "user_id=#{failing.id}): permanent_failure"
      refute log =~ failing.email
      refute log =~ "550"

      assert_email_sent(to: [{"", other.email}])
      other_id = other.id
      failing_id = failing.id

      assert_received {:telemetry_event, [:kanban, :announcement, :email_sent], _,
                       %{user_id: ^other_id}}

      refute_received {:telemetry_event, [:kanban, :announcement, :email_sent], _,
                       %{user_id: ^failing_id}}
    end
  end
end
