defmodule Kanban.Accounts.UserNotifierTest do
  use Kanban.DataCase, async: true

  import Swoosh.TestAssertions

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier

  # The org-admin emails link the Resources guides for setting an
  # Organization up, as absolute URLs, and ask the reader to keep them.
  defp assert_guides(html_body) do
    assert html_body =~ "<strong>Save these guides.</strong>"
    assert html_body =~ "setting up your Organization properly"

    for id <- UserNotifier.org_admin_guide_ids() do
      assert html_body =~ ~s(href="#{KanbanWeb.Endpoint.url()}/resources/#{id}")
    end
  end

  # The sign-up and invitation emails link every Getting started guide, then
  # every For developers guide, before the closing security notice.
  defp assert_new_user_guides(body) do
    assert body =~ "<strong>Getting started.</strong>"

    [getting_started, developers] = String.split(body, "<strong>For developers.</strong>")

    Enum.each(UserNotifier.getting_started_guides(), &assert_guide_listed(getting_started, &1))
    Enum.each(UserNotifier.developer_guides(), &assert_guide_listed(developers, &1))

    assert developers =~ "Do not forward this email to anyone."
  end

  defp assert_guide_listed(section, how_to) do
    assert section =~ ~s(<a href="#{KanbanWeb.Endpoint.url()}/resources/#{how_to.id}">)

    assert section =~
             how_to.description |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

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

    test "links every Getting started guide, then every For developers guide" do
      user = %User{email: "newuser@example.com", name: "New User"}

      {:ok, email} = UserNotifier.deliver_confirmation_instructions(user, "http://x/c")

      assert_new_user_guides(email.html_body)
    end
  end

  describe "the sign-up email's guide lists" do
    test "match the catalog's Getting started and For developers labels" do
      all = KanbanWeb.ResourcesLive.HowToData.all_how_tos()

      assert UserNotifier.getting_started_guides() ==
               Enum.filter(all, &("getting-started" in &1.tags))

      assert UserNotifier.developer_guides() ==
               Enum.filter(all, &("developer" in &1.tags and "getting-started" not in &1.tags))

      assert UserNotifier.getting_started_guides() != []
      assert UserNotifier.developer_guides() != []
    end
  end

  describe "deliver_workspace_invitation/3 (W2219)" do
    test "names the inviter and the workspace and carries the link" do
      url = "https://example.test/invitations/abc_DEF-123"

      assert {:ok, email} =
               UserNotifier.deliver_workspace_invitation(
                 "invitee@example.com",
                 %{target: :workspace, target_name: "Platform", inviter_name: "Ada"},
                 url
               )

      assert email.to == [{"", "invitee@example.com"}]
      assert email.subject == "You're invited to Platform on Stride"
      assert email.html_body =~ "Ada has invited you to the workspace"
      assert email.html_body =~ "<strong>Platform</strong>"
      assert email.html_body =~ ~s|href="#{url}"|
      assert email.html_body =~ "expires in 7 days"
      assert_email_sent(email)
    end

    test "says board for a board invitation and falls back when the inviter has no name" do
      {:ok, email} =
        UserNotifier.deliver_workspace_invitation(
          "invitee@example.com",
          %{target: :board, target_name: "Roadmap", inviter_name: nil},
          "https://example.test/invitations/x"
        )

      assert email.html_body =~ "Someone has invited you to the board"
    end

    test "links the Getting started and For developers guides, as the sign-up email does" do
      {:ok, email} =
        UserNotifier.deliver_workspace_invitation(
          "invitee@example.com",
          %{target: :board, target_name: "Roadmap", inviter_name: "Ada"},
          "https://example.test/invitations/x"
        )

      assert_new_user_guides(email.html_body)
      refute email.html_body =~ "Save these guides."
    end

    test "escapes markup in names and folds line breaks out of the subject" do
      {:ok, email} =
        UserNotifier.deliver_workspace_invitation(
          "invitee@example.com",
          %{
            target: :workspace,
            target_name: "<b>Plat</b>\r\nBcc: x@example.com",
            inviter_name: "<img src=x>"
          },
          "https://example.test/invitations/x"
        )

      refute email.html_body =~ "<b>Plat</b>"
      refute email.html_body =~ "<img src=x>"
      assert email.html_body =~ "&lt;b&gt;Plat&lt;/b&gt;"
      refute email.subject =~ ~r/[\r\n]/
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

    test "links the four setup guides and asks the org-admin to save them" do
      user = %User{email: "new@example.com", name: nil}

      {:ok, email} =
        UserNotifier.deliver_org_admin_confirmation_instructions(user, "Acme", "http://x/c")

      assert_guides(email.html_body)
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

  describe "deliver_org_admin_appointed_notice/2" do
    test "tells an existing account it is now an org-admin and links the setup guides" do
      user = %User{email: "boss@example.com", name: "Ada"}

      assert {:ok, email} = UserNotifier.deliver_org_admin_appointed_notice(user, "Acme Widgets")

      assert email.to == [{"", "boss@example.com"}]
      assert email.subject == "You're now an org-admin of Acme Widgets on Stride"
      assert email.html_body =~ "Hi Ada,"
      assert email.html_body =~ "A Stride site admin has made you an org-admin of"
      assert email.html_body =~ "<strong>Acme Widgets</strong>"
      assert email.html_body =~ ~s(href="#{KanbanWeb.Endpoint.url()}/users/log-in")
      assert email.html_body =~ "If you weren't expecting this"
      refute email.html_body =~ "created an account"
      refute email.html_body =~ "no password yet"
      refute email.html_body =~ "<strong>Getting started.</strong>"
      assert_guides(email.html_body)
      assert_email_sent(email)
    end

    test "escapes markup in the names and folds line breaks out of the subject" do
      user = %User{email: "boss@example.com", name: "<i>Ada</i>"}

      {:ok, email} =
        UserNotifier.deliver_org_admin_appointed_notice(user, "<b>Acme</b>\r\nBcc: x@example.com")

      refute email.html_body =~ "<b>Acme</b>"
      refute email.html_body =~ "<i>Ada</i>"
      assert email.html_body =~ "&lt;b&gt;Acme&lt;/b&gt;"

      assert email.subject ==
               "You're now an org-admin of <b>Acme</b> Bcc: x@example.com on Stride"
    end
  end

  describe "org-admin setup guides" do
    test "every linked guide is a Resources guide, in the order the email lists them" do
      assert UserNotifier.org_admin_guide_ids() == [
               "accepting-an-invitation",
               "administering-your-organization",
               "organization-security-policy",
               "reading-the-organization-audit-log"
             ]

      for id <- UserNotifier.org_admin_guide_ids() do
        assert {:ok, %{title: title}} = KanbanWeb.ResourcesLive.HowToData.get_how_to(id)

        {:ok, email} =
          UserNotifier.deliver_org_admin_appointed_notice(%User{email: "a@example.com"}, "Acme")

        assert email.html_body =~ ~s(/resources/#{id}">#{title}</a>),
               "the email's link text for #{id} must be the guide's title, #{inspect(title)}"
      end
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
