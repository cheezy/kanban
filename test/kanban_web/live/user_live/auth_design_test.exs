defmodule KanbanWeb.UserLive.AuthDesignTest do
  @moduledoc """
  Cross-page regression tests guarding the unified auth design.

  Every auth LiveView (login, registration, confirmation, forgot password,
  reset password, settings) shares the card framing from
  `KanbanWeb.AuthComponents`. If any page accidentally drops the shared
  chrome, these tests fail — catching the regression before it ships.

  Only the design markers are asserted (card chrome classes, icon SVG, page
  title). Internal markup is left alone so legitimate restructuring of an
  individual page does not break the suite.
  """

  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts

  @card_chrome_markers [
    "bg-base-100",
    "rounded-2xl",
    "shadow-xl",
    "border-base-300"
  ]

  defp assert_shared_card_chrome(html, page_label) do
    for marker <- @card_chrome_markers do
      assert html =~ marker,
             "Expected #{page_label} to render the shared card marker #{inspect(marker)}, but it was missing."
    end

    assert html =~ "<svg", "Expected #{page_label} to render an icon SVG inside the card."
  end

  describe "log-in page" do
    # NOTE: The W642-style shared-card-chrome assertions no longer apply to
    # the log-in page — it was rewritten in W652 to use the editorial
    # auth_frame from design_handoff_stride/design_source/screens/auth.jsx.
    # This whole file is slated for deletion in W657. Until then, this test
    # asserts on the new design markers instead of the deprecated chrome.
    test "renders the editorial auth_frame with Sign in title", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Sign in"
      # The auth_frame brand panel renders the rotating signin quote
      assert html =~ "Agents finally have somewhere good to work."
    end
  end

  describe "registration page" do
    test "renders the shared card framing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert_shared_card_chrome(html, "registration")
      assert html =~ "Create Your Account"
    end
  end

  describe "forgot password page" do
    test "renders the shared card framing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert_shared_card_chrome(html, "forgot password")
      assert html =~ "Forgot your password?"
    end
  end

  describe "reset password page" do
    test "renders the shared card framing for a valid token", %{conn: conn} do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert_shared_card_chrome(html, "reset password")
      assert html =~ "Reset password"
    end
  end

  describe "confirmation page" do
    test "renders the shared card framing for a valid token", %{conn: conn} do
      user = unconfirmed_user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _initial_html} = live(conn, ~p"/users/confirm/#{token}")

      html = render(lv)

      assert_shared_card_chrome(html, "confirmation")
      assert html =~ "Account Confirmed!"
    end
  end

  describe "settings page" do
    test "renders the shared card framing for an authenticated user", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert_shared_card_chrome(html, "settings")
      assert html =~ "Account Settings"
      assert html =~ "Profile Information"
      assert html =~ "Change Password"
    end
  end
end
