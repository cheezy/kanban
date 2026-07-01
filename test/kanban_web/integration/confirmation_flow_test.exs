defmodule KanbanWeb.Integration.ConfirmationFlowTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  describe "confirmation-gated registration journey" do
    test "register, wait on pending, get blocked, confirm, onboard, then sign in", %{conn: conn} do
      email = unique_user_email()
      password = valid_user_password()

      # 1. Register through the form.
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, name: "Journey User")
        )

      conn = submit_form(form, conn)

      # 2. Land on the confirmation-pending page with no session.
      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"

      {:ok, _lv, pending_html} = live(conn, redirected_to(conn))
      assert pending_html =~ "Check your email"
      assert pending_html =~ email

      # 3. An authenticated route redirects the session-less visitor.
      assert {:error, {_kind, %{to: "/users/log-in"}}} = live(conn, ~p"/boards")

      # 4. Logging in with correct credentials is denied while unconfirmed and
      #    lands back on the confirmation-pending page with the resend button.
      denied_conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => password}
        })

      refute get_session(denied_conn, :user_token)
      assert redirected_to(denied_conn) == ~p"/users/confirmation-pending?email=#{email}"

      assert Phoenix.Flash.get(denied_conn.assigns.flash, :error) =~
               "confirm your account before signing in"

      # 5. Follow the confirmation token from the email the controller sent.
      assert_receive {:email, %Swoosh.Email{html_body: html_body}}

      [token] = Regex.run(~r{/users/confirm/([^"]+)}, html_body, capture: :all_but_first)

      {:ok, confirm_lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      onboarding_html = render(confirm_lv)

      # 6. The getting-started onboarding renders with the guide links.
      assert onboarding_html =~ "Your account is confirmed"
      assert onboarding_html =~ "Getting started"
      assert has_element?(confirm_lv, ~s{a[href="/resources/creating-your-first-board"]})
      assert has_element?(confirm_lv, ~s{a[href="/resources/inviting-team-members"]})

      # 7. Sign in successfully and reach /boards.
      signed_in_conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => password}
        })

      assert get_session(signed_in_conn, :user_token)
      assert redirected_to(signed_in_conn) == ~p"/boards"

      boards_conn = get(signed_in_conn, ~p"/boards")
      boards_html = html_response(boards_conn, 200)
      assert boards_html =~ "Journey User"
      assert boards_html =~ ~p"/users/log-out"
    end
  end
end
