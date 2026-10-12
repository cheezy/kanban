defmodule Kanban.Notifications.EmailWorkerFailureTest do
  # Swaps the global mailer adapter, so it cannot run concurrently.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Notifications.EmailWorker

  defmodule RejectingMailerAdapter do
    @moduledoc false
    use Swoosh.Adapter

    # Mimics a gen_smtp permanent failure whose reply echoes the recipient.
    @impl true
    def deliver(%Swoosh.Email{to: [{_name, address} | _]}, _config) do
      {:error,
       {:permanent_failure, "smtp.example.com",
        "550 5.1.1 <#{address}>: Recipient address rejected"}}
    end
  end

  setup do
    original = Application.get_env(:kanban, Kanban.Mailer)
    Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
    on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)
    :ok
  end

  test "returns an error so Oban retries, leaves emailed_at unset and logs no private data" do
    user = user_fixture()
    n = notification_fixture(user, %{title: "Private task title"})

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :retries_exceeded} = perform_job(EmailWorker, %{notification_id: n.id})
      end)

    assert is_nil(Repo.reload!(n).emailed_at)
    assert log =~ "notification_id=#{n.id}"
    refute log =~ user.email
    refute log =~ "Private task title"
    refute log =~ "unsubscribe"
  end

  test "never logs or returns an SMTP reply that echoes the recipient address" do
    Application.put_env(:kanban, Kanban.Mailer, adapter: RejectingMailerAdapter)
    user = user_fixture()
    n = notification_fixture(user)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :permanent_failure} = perform_job(EmailWorker, %{notification_id: n.id})
      end)

    assert log =~ "permanent_failure"
    refute log =~ user.email
    refute log =~ "550"
  end

  test "mailer failure emits email_failed" do
    user = user_fixture()
    n = notification_fixture(user, %{title: "Private task title"})

    attach_telemetry([
      [:kanban, :notification, :email_failed],
      [:kanban, :notification, :email_sent]
    ])

    capture_log([level: :warning], fn ->
      assert {:error, :retries_exceeded} = perform_job(EmailWorker, %{notification_id: n.id})
    end)

    id = n.id
    user_id = user.id

    assert_receive {:telemetry_event, [:kanban, :notification, :email_failed], %{count: 1},
                    %{
                      notification_id: ^id,
                      user_id: ^user_id,
                      event_type: :board_access_changed,
                      error: :retries_exceeded
                    } = metadata}

    refute inspect(metadata) =~ user.email
    refute inspect(metadata) =~ "Private task title"
    refute_receive {:telemetry_event, [:kanban, :notification, :email_sent], _, _}
  end

  test "email_failed carries the failure kind, never an SMTP reply that echoes the address" do
    Application.put_env(:kanban, Kanban.Mailer, adapter: RejectingMailerAdapter)
    user = user_fixture()
    n = notification_fixture(user)
    attach_telemetry([:kanban, :notification, :email_failed])

    capture_log([level: :warning], fn ->
      assert {:error, :permanent_failure} = perform_job(EmailWorker, %{notification_id: n.id})
    end)

    assert_receive {:telemetry_event, [:kanban, :notification, :email_failed], %{count: 1},
                    %{error: :permanent_failure} = metadata}

    refute inspect(metadata) =~ user.email
    refute inspect(metadata) =~ "550"
  end
end
