defmodule Kanban.Subscribers.NotifierTest do
  # async: false — the failure tests swap the global Kanban.Mailer adapter via
  # Application.put_env, which is process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Kanban.Subscribers.Notifier
  alias Kanban.Subscribers.Subscriber

  @subscriber %Subscriber{id: 41, email: "notifier-release@example.test", locale: "fr"}
  @confirm "confirm-token_Abc123"
  @unsubscribe "unsubscribe-token_Def456"

  describe "deliver_confirmation/3" do
    test "delivers the confirmation in the subscriber's locale without logging an error" do
      log =
        capture_log(fn ->
          assert :ok = Notifier.deliver_confirmation(@subscriber, @confirm, @unsubscribe)
        end)

      assert_email_sent(fn sent ->
        assert sent.to == [{"", "notifier-release@example.test"}]
        refute sent.subject =~ "Confirm your subscription"
        assert sent.text_body =~ @confirm
      end)

      refute log =~ "release list email delivery failed"
    end
  end

  describe "deliver_confirmation/3 when the mailer fails" do
    setup do
      original = Application.get_env(:kanban, Kanban.Mailer)
      Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
      on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)
      :ok
    end

    test "still returns :ok and logs the failure by its kind only" do
      log =
        capture_log(fn ->
          assert :ok = Notifier.deliver_confirmation(@subscriber, @confirm, @unsubscribe)
        end)

      assert log =~ "release list email delivery failed (kind=retries_exceeded)"
      refute log =~ "notifier-release"
      refute log =~ @confirm
      refute log =~ @unsubscribe
      refute log =~ "smtp.gmail.com"
      assert_no_email_sent()
    end
  end
end
