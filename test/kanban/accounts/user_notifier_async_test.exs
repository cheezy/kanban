defmodule Kanban.Accounts.UserNotifierAsyncTest do
  @moduledoc """
  Pins the off-request (D134) delivery path of `Kanban.Accounts.UserNotifier`.

  The rest of the suite runs with `:async_email_delivery` set to `false`
  (see config/test.exs) so the Swoosh test adapter's assertions are
  deterministic. This module flips the flag on to exercise the supervised
  `Task.Supervisor` dispatch. It is `async: false` so it runs in isolation and
  the global env toggle cannot race concurrent tests.
  """
  use Kanban.DataCase, async: false

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier

  setup do
    previous = Application.get_env(:kanban, :async_email_delivery)
    Application.put_env(:kanban, :async_email_delivery, true)
    on_exit(fn -> Application.put_env(:kanban, :async_email_delivery, previous) end)
    :ok
  end

  test "delivers via the supervised Task and the email reaches the caller" do
    user = %User{email: "async@example.com", name: "Async User"}

    # The public function returns immediately with the built email; delivery is
    # dispatched to Kanban.TaskSupervisor. The Swoosh test adapter delivers to
    # the $callers chain, which start_child propagates, so a blocking
    # assert_receive still observes the email once the task runs.
    assert {:ok, email} =
             UserNotifier.deliver_confirmation_instructions(user, "http://example.com/confirm")

    assert email.to == [{"", "async@example.com"}]
    assert_receive {:email, ^email}, 1000
  end

  test "returns the built email synchronously without depending on delivery" do
    user = %User{email: "async2@example.com", name: "Async Two"}

    # The caller gets {:ok, email} built in-band; the actual send is dispatched
    # to the supervised Task, so the return does not depend on Mailer.deliver.
    assert {:ok, %Swoosh.Email{subject: "Reset your Stride password"} = email} =
             UserNotifier.deliver_reset_password_instructions(user, "http://example.com/reset")

    # Drain the async delivery so the mailbox does not leak into other tests.
    assert_receive {:email, ^email}, 1000
  end
end
