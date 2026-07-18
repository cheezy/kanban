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
      assert html =~ "Set up your coding agent"
      assert html =~ "Sign in to your account"
      assert html =~ "Create your first board"
      assert html =~ "Generate an API token"
      assert html =~ "Add your team"
      refute html =~ "Account confirmed"
    end

    test "presents a copyable agent onboarding prompt as the first step", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      html = render(lv)

      assert html =~ "Paste this prompt into your agent"
      assert html =~ "/api/agent/onboarding"
      assert html =~ ".stride_auth.md"
      assert html =~ ".stride.md"
      assert has_element?(lv, "#agent-onboarding-prompt")
      assert has_element?(lv, "button", "Copy")
    end

    test "links to the getting-started guides in a new tab", %{
      conn: conn,
      unconfirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      render(lv)

      for path <- [
            "/resources/creating-your-first-board",
            "/resources/api-authentication",
            "/resources/inviting-team-members"
          ] do
        assert has_element?(lv, ~s{a[href="#{path}"][target="_blank"]})
      end
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

  describe "Install the Stride plugin picker" do
    setup %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      %{lv: lv}
    end

    test "renders the new step with a tab for each of the six agents", %{lv: lv} do
      html = render(lv)

      assert html =~ "Install the Stride plugin"

      for {key, label} <- [
            {"claude_code", "Claude Code"},
            {"copilot", "Copilot"},
            {"gemini", "Gemini"},
            {"codex", "Codex"},
            {"opencode", "OpenCode"},
            {"pi", "Pi"}
          ] do
        assert has_element?(lv, ~s{button[role="tab"][phx-value-agent="#{key}"]}, label)
      end
    end

    test "renumbers the getting-started steps sequentially after inserting the new step", %{
      lv: lv
    } do
      html = render(lv)

      titles = [
        "Set up your coding agent",
        "Install the Stride plugin",
        "Sign in to your account",
        "Create your first board",
        "Generate an API token",
        "Add your team"
      ]

      positions = Enum.map(titles, fn title -> :binary.match(html, title) |> elem(0) end)
      assert positions == Enum.sort(positions), "onboarding steps are out of order"
    end

    test "defaults to Claude Code and shows its workflow + ideation commands and links", %{lv: lv} do
      html = render(lv)

      assert html =~ "/plugin install stride@stride-marketplace"
      assert html =~ "/plugin install stride-ideation@stride-marketplace"

      assert has_element?(
               lv,
               ~s{a[href="https://github.com/cheezy/stride-marketplace"][target="_blank"]}
             )

      assert has_element?(
               lv,
               ~s{a[href="https://github.com/cheezy/stride-ideation"][target="_blank"]}
             )

      assert html =~ "Installs through the Stride marketplace."
      assert has_element?(lv, "#workflow-copy-claude_code")
      assert has_element?(lv, "#ideation-copy-claude_code")
    end

    test "selecting a tab swaps the panel to that agent's commands", %{lv: lv} do
      html = lv |> element(~s{button[phx-value-agent="copilot"]}) |> render_click()

      assert html =~ "copilot plugin install https://github.com/cheezy/stride-copilot"
      assert html =~ "copilot plugin install https://github.com/cheezy/stride-copilot-ideation"

      assert has_element?(
               lv,
               ~s{a[href="https://github.com/cheezy/stride-copilot"][target="_blank"]}
             )

      # The default agent's command is no longer in the DOM (only the selected panel renders).
      refute html =~ "/plugin install stride@stride-marketplace"
    end

    test "Pi renders as an individual plugin with no marketplace and no ideation plugin", %{
      lv: lv
    } do
      html = lv |> element(~s{button[phx-value-agent="pi"]}) |> render_click()

      assert html =~ "https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh"
      assert html =~ "Installs from its own repository — no marketplace."
      refute html =~ "Installs through the Stride marketplace."
      assert html =~ "No separate ideation plugin yet."
      refute has_element?(lv, "#ideation-copy-pi")
    end

    test "leaves the selection unchanged when given an unknown agent key", %{lv: lv} do
      # get/1 is nil-safe; a tampered phx-value must not crash or blank the panel.
      html = render_click(lv, "select_agent", %{"agent" => "not-a-real-agent"})

      assert html =~ "/plugin install stride@stride-marketplace"
    end
  end
end
