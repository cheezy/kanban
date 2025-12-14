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
      assert email.from == {"Stride Support", "noreply@StrideLikeABoss.com"}
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
      assert email.from == {"Stride Support", "noreply@StrideLikeABoss.com"}
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

  describe "email formatting" do
    test "all emails use consistent from address" do
      user = %User{email: "test@example.com", confirmed_at: nil, name: "Test"}
      url = "http://example.com/test"

      {:ok, email1} = UserNotifier.deliver_confirmation_instructions(user, url)
      {:ok, email2} = UserNotifier.deliver_update_email_instructions(user, url)

      assert email1.from == {"Stride Support", "noreply@StrideLikeABoss.com"}
      assert email2.from == {"Stride Support", "noreply@StrideLikeABoss.com"}
    end

    test "all emails use HTML format" do
      user = %User{email: "test@example.com", name: "Test"}
      url = "http://example.com/test"

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, url)

      assert email.html_body =~ "<div>"
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
