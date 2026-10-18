defmodule Kanban.Accounts.UserNotifierTest do
  use Kanban.DataCase, async: true

  import Swoosh.TestAssertions

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier

  describe "deliver_update_email_instructions/2" do
    test "sends email with update instructions" do
      user = %User{email: "user@example.com", name: "Test User"}
      url = "http://example.com/users/settings/confirm-email/token123"

      assert {:ok, email} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email.to == [{"", "user@example.com"}]
      assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
      assert email.subject == "Update email instructions"
      assert email.html_body =~ "Hi Test User"
      assert email.html_body =~ url
      assert email.html_body =~ "You are receiving this email because you requested to change the"

      assert email.html_body =~
               "If this change was not requested by you, please ignore this email"

      assert_email_sent(email)
    end

    test "includes user name in greeting" do
      user = %User{email: "alice@example.com", name: "Alice"}
      url = "http://example.com/token"

      assert {:ok, email} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email.html_body =~ "Hi Alice"
    end
  end

  describe "deliver_confirmation_instructions/2" do
    test "sends confirmation email with correct content" do
      user = %User{email: "newuser@example.com", name: "New User"}
      url = "http://example.com/users/confirm/token123"

      assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.to == [{"", "newuser@example.com"}]
      assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
      assert email.subject == "Confirm your Stride account"
      assert email.html_body =~ "Hi New User"
      assert email.html_body =~ url
      assert email.html_body =~ "We received your request to create an account with Stride"

      assert_email_sent(email)
    end

    test "includes security notice for users who didn't sign up" do
      user = %User{email: "someone@example.com", name: "Someone"}
      url = "http://example.com/confirm/token"

      assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.html_body =~
               "You can safely ignore this email If you didn't create an account with us."
    end
  end

  describe "deliver_org_admin_confirmation_instructions/3" do
    test "names the Organization and says a site admin created the account" do
      user = %User{email: "new@example.com", name: nil}
      url = "http://example.com/users/confirm/token123"

      assert {:ok, email} =
               UserNotifier.deliver_org_admin_confirmation_instructions(user, "Acme Widgets", url)

      assert email.to == [{"", "new@example.com"}]
      assert email.subject == "Confirm your Stride account for Acme Widgets"
      assert email.html_body =~ "A Stride site admin has created an account"
      assert email.html_body =~ "<strong>Acme Widgets</strong>"
      assert email.html_body =~ url
      assert email.html_body =~ "second email lets you choose your password."
      refute email.html_body =~ "We received your request"
      assert_email_sent(email)
    end

    test "escapes markup in the Organization name and folds line breaks out of the subject" do
      user = %User{email: "new@example.com", name: nil}

      {:ok, email} =
        UserNotifier.deliver_org_admin_confirmation_instructions(
          user,
          "<b>Acme</b>\r\nBcc: x@example.com",
          "http://example.com/x"
        )

      refute email.html_body =~ "<b>Acme</b>"
      assert email.html_body =~ "&lt;b&gt;Acme&lt;/b&gt;"
      refute email.subject =~ ~r/[\r\n]/
      assert email.subject == "Confirm your Stride account for <b>Acme</b> Bcc: x@example.com"
    end
  end

  describe "deliver_org_admin_password_instructions/4" do
    test "explains the account has no password yet and how to get a new link" do
      user = %User{email: "new@example.com", name: nil}
      url = "http://example.com/users/reset-password/token123"

      assert {:ok, email} =
               UserNotifier.deliver_org_admin_password_instructions(user, "Acme Widgets", url, 15)

      assert email.subject == "Choose your Stride password"
      assert email.html_body =~ "account for <strong>Acme Widgets</strong>"
      assert email.html_body =~ "has no password yet"
      assert email.html_body =~ url
      assert email.html_body =~ "This link expires in 15 minutes."
      assert email.html_body =~ ~s("Forgot your password?")
      refute email.html_body =~ "requested to reset"
      assert_email_sent(email)
    end

    test "escapes markup in the Organization name" do
      user = %User{email: "new@example.com", name: nil}

      {:ok, email} =
        UserNotifier.deliver_org_admin_password_instructions(
          user,
          "<script>alert(1)</script>",
          "http://example.com/x",
          15
        )

      refute email.html_body =~ "<script>alert(1)</script>"
      assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  describe "email formatting" do
    test "all emails use consistent from address" do
      user = %User{email: "test@example.com", confirmed_at: nil, name: "Test"}
      url = "http://example.com/test"

      {:ok, email1} = UserNotifier.deliver_confirmation_instructions(user, url)
      {:ok, email2} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email1.from == {"Stride Support", "noreply@stridelikeaboss.com"}
      assert email2.from == {"Stride Support", "noreply@stridelikeaboss.com"}
    end

    test "all emails use HTML format" do
      user = %User{email: "test@example.com", name: "Test"}
      url = "http://example.com/test"

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.html_body =~ "<div>"
    end
  end

  describe "W395 XSS / HTML-injection defense in email bodies" do
    @malicious_name "<script>alert(1)</script>"

    test "deliver_update_email_instructions escapes user.name" do
      user = %User{email: "user@example.com", name: @malicious_name}
      {:ok, email} = UserNotifier.deliver_update_email_instructions(user, "http://example.com/x")

      refute email.html_body =~ @malicious_name
      assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "deliver_confirmation_instructions escapes user.name" do
      user = %User{email: "user@example.com", name: @malicious_name}
      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, "http://example.com/x")

      refute email.html_body =~ @malicious_name
      assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "deliver_reset_password_instructions escapes user.name" do
      user = %User{email: "user@example.com", name: @malicious_name}

      {:ok, email} =
        UserNotifier.deliver_reset_password_instructions(user, "http://example.com/x")

      refute email.html_body =~ @malicious_name
      assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "nil user.name renders an empty greeting without crashing" do
      user = %User{email: "user@example.com", name: nil}
      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, "http://example.com/x")

      assert email.html_body =~ "Hi ,"
    end

    test "ampersand in user.name is escaped" do
      user = %User{email: "user@example.com", name: "Pete & Repeat"}
      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, "http://example.com/x")

      refute email.html_body =~ "Pete & Repeat"
      assert email.html_body =~ "Pete &amp; Repeat"
    end
  end

  describe "email delivery" do
    test "returns ok tuple with email on successful delivery" do
      user = %User{email: "test@example.com", name: "Test"}
      url = "http://example.com/test"

      result = UserNotifier.deliver_confirmation_instructions(user, url)

      assert {:ok, %Swoosh.Email{}} = result
    end

    test "email contains HTML body only (no text)" do
      user = %User{email: "test@example.com", confirmed_at: nil, name: "Test"}
      url = "http://example.com/test"

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert is_binary(email.html_body)
      assert email.text_body == nil
    end
  end
end
