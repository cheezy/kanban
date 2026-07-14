defmodule Kanban.Accounts.ConfirmationDeliveryTest do
  # async: false — the delivery-failure test swaps the global Kanban.Mailer
  # adapter via Application.put_env, which is process-global.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Swoosh.TestAssertions
  import ExUnit.CaptureLog

  alias Kanban.Accounts

  defp confirm_url(token), do: "http://localhost/users/confirm/#{token}"

  describe "deliver_user_confirmation_instructions/2 success" do
    test "sends the confirmation email and returns {:ok, email} without logging an error" do
      user = unconfirmed_user_fixture()

      log =
        capture_log(fn ->
          assert {:ok, _email} =
                   Accounts.deliver_user_confirmation_instructions(user, &confirm_url/1)
        end)

      assert_email_sent(subject: "Confirm your Stride account")
      refute log =~ "Failed to deliver confirmation email"
    end
  end

  describe "deliver_user_confirmation_instructions/2 when the mailer fails" do
    setup do
      original = Application.get_env(:kanban, Kanban.Mailer)
      Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
      on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)
      :ok
    end

    test "returns the delivery error instead of a false {:ok, _}" do
      user = unconfirmed_user_fixture()

      capture_log(fn ->
        assert {:error, _reason} =
                 Accounts.deliver_user_confirmation_instructions(user, &confirm_url/1)
      end)
    end

    test "logs the failure with the user id so it is no longer swallowed" do
      user = unconfirmed_user_fixture()

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   Accounts.deliver_user_confirmation_instructions(user, &confirm_url/1)
        end)

      assert log =~ "Failed to deliver confirmation email for user #{user.id}"
    end
  end

  describe "deliver_user_confirmation_instructions/2 for an already-confirmed user" do
    test "returns {:error, :already_confirmed} without logging a delivery error" do
      user = user_fixture()

      log =
        capture_log(fn ->
          assert {:error, :already_confirmed} =
                   Accounts.deliver_user_confirmation_instructions(user, &confirm_url/1)
        end)

      refute log =~ "Failed to deliver confirmation email"
    end
  end
end
