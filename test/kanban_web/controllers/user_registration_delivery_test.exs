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

    # Delivery is dispatched off the request path (D134), so the response is
    # identical whether or not the send succeeds — the user lands on the
    # confirmation-pending page (which offers a resend button) and the failure
    # reason reaches the logs instead of the response.
    test "responds uniformly and logs the reason", %{conn: conn} do
      email = unique_user_email()

      log =
        capture_log(fn ->
          conn =
            post(conn, ~p"/users/register", %{
              "user" => %{"email" => email, "password" => valid_user_password()}
            })

          assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"
          refute Phoenix.Flash.get(conn.assigns.flash, :error)
        end)

      # The delivery reason is not swallowed — it reaches the logs.
      assert log =~ "auth email delivery failed"
    end
  end
end
