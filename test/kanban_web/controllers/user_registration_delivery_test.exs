defmodule KanbanWeb.UserRegistrationDeliveryTest do
  # async: false — the delivery-failure test swaps the global Kanban.Mailer
  # adapter via Application.put_env, which is process-global.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Swoosh.TestAssertions
  import ExUnit.CaptureLog

  describe "POST /users/register email delivery" do
    test "sends a confirmation email to the registered address", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"
      assert_email_sent(subject: "Confirm your Stride account", to: [{"", email}])
    end
  end

  describe "POST /users/register when the mailer fails" do
    setup do
      original = Application.get_env(:kanban, Kanban.Mailer)
      Application.put_env(:kanban, Kanban.Mailer, adapter: Kanban.FailingMailerAdapter)
      on_exit(fn -> Application.put_env(:kanban, Kanban.Mailer, original) end)
      :ok
    end

    test "surfaces the failure to the user and logs the reason", %{conn: conn} do
      email = unique_user_email()

      log =
        capture_log(fn ->
          conn =
            post(conn, ~p"/users/register", %{
              "user" => %{"email" => email, "password" => valid_user_password()}
            })

          # The user still lands on the confirmation-pending page (with a resend
          # option) but is told the email could not be sent — not silently led
          # to believe it was delivered.
          assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"

          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
                   "couldn't send the confirmation email"
        end)

      # The previously-swallowed delivery reason now reaches the logs.
      assert log =~ "Failed to deliver confirmation email"
    end
  end
end
