defmodule Kanban.Notifications.EmailWorkerFailureTest do
  # Swaps the global mailer adapter, so it cannot run concurrently.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.NotificationsFixtures

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
end
