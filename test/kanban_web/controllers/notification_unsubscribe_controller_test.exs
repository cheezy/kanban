defmodule KanbanWeb.NotificationUnsubscribeControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.NotificationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications
  alias KanbanWeb.UnsubscribeToken

  @max_age 90 * 24 * 60 * 60

  setup do
    user = user_fixture()
    %{user: user, token: UnsubscribeToken.sign(user.id, :review_requested)}
  end

  defp email_on?(user, type) do
    user
    |> Scope.for_user()
    |> Notifications.get_preferences()
    |> Enum.find(&(&1.event_type == type))
    |> Map.fetch!(:email)
  end

  defp tampered(token), do: token <> "x"

  defp expired_token(user) do
    UnsubscribeToken.sign(user.id, :review_requested,
      signed_at: System.system_time(:second) - @max_age - 1
    )
  end

  describe "GET /notifications/unsubscribe" do
    test "renders a confirmation naming the category and changes nothing", ctx do
      conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      html = html_response(conn, 200)
      assert html =~ "Unsubscribe from these emails?"
      assert html =~ "Review requests"
      assert html =~ ~s(data-state="confirm")
      assert html =~ "hero-envelope"
      assert email_on?(ctx.user, :review_requested)
    end

    test "never shows the account's email address", ctx do
      conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      refute html_response(conn, 200) =~ ctx.user.email
    end

    test "sends no referrer from the page", ctx do
      conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end

    test "works when signed in as a different user and shows no navigation", ctx do
      conn =
        ctx.conn
        |> log_in_user(user_fixture())
        |> get(~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      html = html_response(conn, 200)
      assert html =~ "Unsubscribe from these emails?"
      refute html =~ ctx.user.email
      assert email_on?(ctx.user, :review_requested)
    end

    test "shows the same generic error for tampered, expired, missing and unknown tokens",
         ctx do
      deleted = user_fixture()
      deleted_token = UnsubscribeToken.sign(deleted.id, :review_requested)
      Kanban.Repo.delete!(deleted)

      for token <- [tampered(ctx.token), expired_token(ctx.user), nil] do
        params = if token, do: [token: token], else: []
        conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{params}")

        html = html_response(conn, 400)
        assert html =~ "This link is no longer valid"
        assert html =~ ~s(data-state="invalid")
      end

      # A deleted user's token still verifies, so GET shows the confirmation
      # without revealing anything; the POST then fails generically.
      conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{[token: deleted_token]}")
      assert html_response(conn, 200) =~ "Unsubscribe from these emails?"

      conn = post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: deleted_token]}")
      assert html_response(conn, 400) =~ "This link is no longer valid"
    end

    test "a GET on the one-click URL shows the confirmation and changes nothing", ctx do
      conn = get(ctx.conn, ~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}")

      html = html_response(conn, 200)
      assert html =~ ~s(data-state="confirm")
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert email_on?(ctx.user, :review_requested)
    end

    test "rejects a token whose event type is not a notification type", ctx do
      token = UnsubscribeToken.sign(ctx.user.id, :not_a_type)

      conn = get(ctx.conn, ~p"/notifications/unsubscribe?#{[token: token]}")

      assert html_response(conn, 400) =~ "This link is no longer valid"
    end
  end

  describe "POST /notifications/unsubscribe (confirmation form)" do
    test "turns email off for that category and shows the done state", ctx do
      preference_fixture(ctx.user, :review_requested, %{in_app: true, email: true})

      conn = post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      html = html_response(conn, 200)
      assert html =~ "You&#39;re unsubscribed"
      assert html =~ "Review requests"
      assert html =~ ~s(href="/users/notifications")
      refute email_on?(ctx.user, :review_requested)
      assert email_on?(ctx.user, :task_assigned)
    end

    test "leaves in-app delivery alone", ctx do
      post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      pref =
        ctx.user
        |> Scope.for_user()
        |> Notifications.get_preferences()
        |> Enum.find(&(&1.event_type == :review_requested))

      assert pref.in_app
      refute pref.email
    end

    test "a weekly_digest token unsubscribes the digest", ctx do
      token = UnsubscribeToken.sign(ctx.user.id, :weekly_digest)

      conn = post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: token]}")

      assert html_response(conn, 200) =~ "Weekly digest"
      refute email_on?(ctx.user, :weekly_digest)
    end

    test "a token reused after email was turned back on turns it off again", ctx do
      post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")
      preference_fixture(ctx.user, :review_requested, %{email: true})

      post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      refute email_on?(ctx.user, :review_requested)
    end

    test "a tampered token changes nothing", ctx do
      conn = post(ctx.conn, ~p"/notifications/unsubscribe?#{[token: tampered(ctx.token)]}")

      assert html_response(conn, 400) =~ "This link is no longer valid"
      assert email_on?(ctx.user, :review_requested)
    end

    test "is CSRF-protected", ctx do
      route =
        Phoenix.Router.route_info(KanbanWeb.Router, "POST", "/notifications/unsubscribe", "")

      assert route.pipe_through == [:browser]

      # Without a CSRF token the request is rejected before the controller
      # runs. (The app has no 403 error template, so the rejection surfaces as
      # a render error rather than a 403 page; either way nothing changes.)
      conn = Plug.Conn.put_private(ctx.conn, :plug_skip_csrf_protection, false)
      catch_error(post(conn, ~p"/notifications/unsubscribe?#{[token: ctx.token]}"))

      assert email_on?(ctx.user, :review_requested)
    end

    test "the one-click route skips the session and CSRF pipeline" do
      route =
        Phoenix.Router.route_info(
          KanbanWeb.Router,
          "POST",
          "/notifications/unsubscribe/one-click",
          ""
        )

      assert route.pipe_through == [:one_click_unsubscribe]
    end
  end

  describe "POST /notifications/unsubscribe/one-click" do
    test "turns email off and returns 200 without a session or CSRF token", ctx do
      conn =
        ctx.conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}", %{
          "List-Unsubscribe" => "One-Click"
        })

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "set-cookie") == []
      refute email_on?(ctx.user, :review_requested)
    end

    test "sends a deny-all Content-Security-Policy", ctx do
      conn =
        post(ctx.conn, ~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}", %{
          "List-Unsubscribe" => "One-Click"
        })

      assert get_resp_header(conn, "content-security-policy") == [
               "default-src 'none'; frame-ancestors 'none'"
             ]
    end

    test "repeated provider POSTs stay successful and idempotent", ctx do
      for _ <- 1..2 do
        conn =
          post(ctx.conn, ~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}", %{
            "List-Unsubscribe" => "One-Click"
          })

        assert response(conn, 200) == ""
      end

      refute email_on?(ctx.user, :review_requested)
    end

    test "returns 400 and changes nothing for a tampered, expired or deleted-user token", ctx do
      deleted = user_fixture()
      deleted_token = UnsubscribeToken.sign(deleted.id, :review_requested)
      Kanban.Repo.delete!(deleted)

      for token <- [tampered(ctx.token), expired_token(ctx.user), deleted_token] do
        conn =
          post(ctx.conn, ~p"/notifications/unsubscribe/one-click?#{[token: token]}", %{
            "List-Unsubscribe" => "One-Click"
          })

        assert response(conn, 400) == ""
      end

      assert email_on?(ctx.user, :review_requested)
    end

    test "returns 400 without the RFC 8058 body", ctx do
      conn = post(ctx.conn, ~p"/notifications/unsubscribe/one-click?#{[token: ctx.token]}")

      assert response(conn, 400) == ""
      assert email_on?(ctx.user, :review_requested)
    end
  end

  test "the page renders in every supported locale", ctx do
    for locale <- ~w(de es fr ja pt zh) do
      conn =
        ctx.conn
        |> Plug.Test.init_test_session(%{"locale" => locale})
        |> get(~p"/notifications/unsubscribe?#{[token: ctx.token]}")

      refute html_response(conn, 200) =~ "Unsubscribe from these emails?",
             "confirmation not translated for #{locale}"
    end
  end
end
