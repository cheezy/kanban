defmodule KanbanWeb.Integration.ConfirmationResendFlowTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  describe "returning-user resend recovery journey" do
    @tag :capture_log
    test "register, blocked login, resend, confirm via the new link, then sign in", %{conn: conn} do
      email = unique_user_email()
      password = valid_user_password()

      # 1. Register through the form; the first confirmation email is sent.
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, name: "Resend Journey")
        )

      conn = submit_form(form, conn)

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"
      assert_receive {:email, %Swoosh.Email{html_body: first_html_body}}
      assert first_html_body =~ "/users/confirm/"

      # 2. A blocked login attempt redirects to the resend page — the user who
      #    lost the first email recovers from the login form itself.
      denied_conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => password}
        })

      refute get_session(denied_conn, :user_token)
      assert redirected_to(denied_conn) == ~p"/users/confirmation-pending?email=#{email}"

      assert Phoenix.Flash.get(denied_conn.assigns.flash, :error) =~
               "confirm your account before signing in"

      # 3. The resend page delivers a fresh confirmation email.
      {:ok, pending_lv, pending_html} = live(conn, redirected_to(denied_conn))
      assert pending_html =~ "Check your email"

      pending_lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(pending_lv) =~ "If your email is in our system"
      assert_receive {:email, %Swoosh.Email{html_body: resent_html_body}}

      # 4. A second resend inside the cooldown is throttled — no third email.
      pending_lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(pending_lv) =~ "Please wait a moment before requesting another email"
      refute_receive {:email, _}, 100

      # 5. Follow the resent link; the account confirms and onboarding renders.
      [token] =
        Regex.run(~r{/users/confirm/([^"]+)}, resent_html_body, capture: :all_but_first)

      {:ok, confirm_lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      assert render(confirm_lv) =~ "Your account is confirmed"

      # 6. Reusing the same link is rejected: confirming deleted every confirm
      #    token, so the second visit redirects to the login page.
      {:ok, reused_lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      assert_redirect(reused_lv, ~p"/users/log-in", 1_000)

      # 7. The confirmed user signs in successfully.
      signed_in_conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => password}
        })

      assert get_session(signed_in_conn, :user_token)
      assert redirected_to(signed_in_conn) == ~p"/boards"
    end

    @tag :capture_log
    test "login-page resend link leads to the email-entry fallback and a neutral resend", %{
      conn: conn
    } do
      user = unconfirmed_user_fixture()

      # 1. The login page links to the resend flow without requiring a failed
      #    sign-in; following it lands on the email-entry fallback state.
      {:ok, login_lv, login_html} = live(conn, ~p"/users/log-in")
      assert login_html =~ "Resend confirmation email"

      {:ok, pending_lv, pending_html} =
        login_lv
        |> element(~s{a[href="/users/confirmation-pending"]}, "Resend confirmation email")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/confirmation-pending")

      assert pending_html =~ "Resend confirmation email"
      assert has_element?(pending_lv, "#resend_confirmation_form")

      # 2. Submitting the email delivers a confirmation link and answers with
      #    the neutral, enumeration-safe message.
      pending_lv
      |> form("#resend_confirmation_form", user: %{email: user.email})
      |> render_submit()

      html = render(pending_lv)
      assert html =~ "If your email is in our system"
      assert html =~ "Check your email"
      assert_receive {:email, %Swoosh.Email{html_body: html_body}}
      assert html_body =~ "/users/confirm/"
    end
  end
end
