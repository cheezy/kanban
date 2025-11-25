defmodule Kanban.Accounts.UserNotifierTest do
  use Kanban.DataCase, async: true

  import Swoosh.TestAssertions

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier

  describe "deliver_update_email_instructions/2" do
    test "sends email with update instructions" do
      user = %User{email: "user@example.com"}
      url = "http://example.com/users/settings/confirm-email/token123"

      assert {:ok, email} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email.to == [{"", "user@example.com"}]
      assert email.from == {"Stride", "contact@example.com"}
      assert email.subject == "Update email instructions"
      assert email.text_body =~ "Hi user@example.com"
      assert email.text_body =~ url
      assert email.text_body =~ "You can change your email by visiting the URL below"
      assert email.text_body =~ "If you didn't request this change, please ignore this"

      assert_email_sent(email)
    end

    test "includes user email in greeting" do
      user = %User{email: "alice@example.com"}
      url = "http://example.com/token"

      assert {:ok, email} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email.text_body =~ "Hi alice@example.com"
    end
  end

  describe "deliver_confirmation_instructions/2" do
    test "sends confirmation email with correct content" do
      user = %User{email: "newuser@example.com"}
      url = "http://example.com/users/confirm/token123"

      assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.to == [{"", "newuser@example.com"}]
      assert email.from == {"Stride", "contact@example.com"}
      assert email.subject == "Confirmation instructions"
      assert email.text_body =~ "Hi newuser@example.com"
      assert email.text_body =~ url
      assert email.text_body =~ "You can confirm your account by visiting the URL below"

      assert_email_sent(email)
    end

    test "includes security notice for users who didn't sign up" do
      user = %User{email: "someone@example.com"}
      url = "http://example.com/confirm/token"

      assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.text_body =~ "If you didn't create an account with us, please ignore this"
    end
  end

  describe "email formatting" do
    test "all emails use consistent from address" do
      user = %User{email: "test@example.com", confirmed_at: nil}
      url = "http://example.com/test"

      {:ok, email1} = UserNotifier.deliver_confirmation_instructions(user, url)
      {:ok, email2} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email1.from == {"Stride", "contact@example.com"}
      assert email2.from == {"Stride", "contact@example.com"}
    end

    test "all emails include separator lines for readability" do
      user = %User{email: "test@example.com"}
      url = "http://example.com/test"

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.text_body =~ "=============================="
    end
  end

  describe "email delivery" do
    test "returns ok tuple with email on successful delivery" do
      user = %User{email: "test@example.com"}
      url = "http://example.com/test"

      result = UserNotifier.deliver_confirmation_instructions(user, url)

      assert {:ok, %Swoosh.Email{}} = result
    end

    test "email contains text body only (no HTML)" do
      user = %User{email: "test@example.com", confirmed_at: nil}
      url = "http://example.com/test"

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert is_binary(email.text_body)
      assert email.html_body == nil
    end
  end
end
