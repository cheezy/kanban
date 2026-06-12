defmodule KanbanWeb.UserLive.ConfirmationTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders getting-started onboarding after confirmation", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      html = render(lv)
      assert html =~ "Your account is confirmed"
      assert html =~ "Getting started"
      assert html =~ "Sign in to your account"
      assert html =~ "Create your first board"
      assert html =~ "Generate an API token"
      assert html =~ "Add your team"
      refute html =~ "Account confirmed"
    end

    test "links to both getting-started guides", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      render(lv)

      assert has_element?(lv, ~s{a[href="/resources/creating-your-first-board"]})
      assert has_element?(lv, ~s{a[href="/resources/inviting-team-members"]})
    end

    test "describes the board-level API token flow without exposing a token", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      html = render(lv)

      # Accurate navigation: Tokens tab on the board, AI-optimized boards only.
      assert html =~ "open the Tokens tab"
      assert html =~ "AI-optimized boards"
      # Security reminder; the confirmation token itself is never rendered.
      assert html =~ "shown only once"
      assert html =~ "keep it secret"
      refute html =~ token
    end

    test "renders inside the centered, theme-aware auth_frame", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      html = render(lv)

      # Centered, theme-following shell — no light-lock, no editorial gradient.
      assert html =~ ~s(class="stride-screen")
      assert html =~ "background: var(--bg)"
      refute html =~ "data-stride-auth-frame"
      refute html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "renders already confirmed message when trying to confirm again", %{
      conn: conn,
      unconfirmed_user: user
    } do
      first_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, user} = Accounts.confirm_user(first_token)

      {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "confirm")
      Kanban.Repo.insert!(user_token)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{encoded_token}")

      flash = assert_redirect(lv, ~p"/users/log-in", 1_000)
      assert flash["info"] =~ "already been confirmed"
    end

    test "confirms the user account", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      render(lv)

      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "does not confirm twice with the same token", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      render(lv)

      {:ok, lv2, _html} = live(conn, ~p"/users/confirm/#{token}")

      assert_redirect(lv2, ~p"/users/log-in", 1_000)
    end

    test "redirects to login for invalid token", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/invalid-token")

      flash = assert_redirect(lv, ~p"/users/log-in", 1_000)
      assert flash["error"] =~ "Confirmation link is invalid or has expired"
    end
  end
end
