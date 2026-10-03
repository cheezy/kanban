defmodule KanbanWeb.Emails.NotificationEmailTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias KanbanWeb.Emails.NotificationEmail
  alias KanbanWeb.UnsubscribeToken

  defp notification(user, attrs) do
    struct!(
      %Notification{
        id: System.unique_integer([:positive]),
        user_id: user.id,
        event_type: :review_requested,
        title: "W1 is ready for review",
        url_path: "/review"
      },
      attrs
    )
  end

  defp build_email(user, attrs) do
    user
    |> notification(attrs)
    |> NotificationEmail.build(user)
  end

  defp unsubscribe_url(email) do
    [_, url] = Regex.run(~r/\A<(.+)>\z/, email.headers["List-Unsubscribe"])
    url
  end

  setup do
    %{user: user_fixture()}
  end

  describe "build/2" do
    test "addresses the user with subject, HTML and text bodies", %{user: user} do
      email = build_email(user, %{})

      assert email.to == [{"", user.email}]
      assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
      assert email.subject == "[Stride] Review requested"
      assert email.html_body =~ "W1 is ready for review"
      assert email.text_body =~ "W1 is ready for review"
      assert email.html_body =~ ~s(href="#{KanbanWeb.Endpoint.url()}/review")
      assert email.text_body =~ "#{KanbanWeb.Endpoint.url()}/review"
    end

    test "renders a distinct subject and non-empty bodies for every event type", %{user: user} do
      subjects =
        for type <- Notifications.event_types() do
          email = build_email(user, %{event_type: type})

          assert "[Stride] " <> heading = email.subject
          assert heading != ""
          assert email.html_body != ""
          assert email.text_body != ""
          email.subject
        end

      assert length(Enum.uniq(subjects)) == length(Notifications.event_types())

      for type <- [
            :task_reviewed,
            :task_unclaimed,
            :board_access_changed,
            :after_goal_failed,
            :target_status_changed,
            :comment_added,
            :mentioned
          ] do
        assert %{subject: "[Stride] " <> _} =
                 build_email(user, %{event_type: type})
      end
    end

    test "a board access notice names the board once and words the change", %{user: user} do
      board = board_fixture(user, %{name: "Roadmap"})

      email =
        build_email(user, %{
          event_type: :board_access_changed,
          title: "Roadmap",
          board: board,
          url_path: "/boards/#{board.id}",
          metadata: %{"change" => "added", "access" => "modify", "tokens_revoked" => 0}
        })

      assert email.subject == "[Stride] Your board access changed"
      assert email.text_body =~ "Roadmap"
      assert email.text_body =~ "You were added with Can Edit access."
      refute email.text_body =~ "Board: Roadmap"
      assert email.text_body =~ "#{KanbanWeb.Endpoint.url()}/boards/#{board.id}"
    end

    test "a removal notice has no board but names it and counts revoked tokens", %{user: user} do
      email =
        build_email(user, %{
          event_type: :board_access_changed,
          title: "Roadmap",
          url_path: "/boards",
          metadata: %{"change" => "removed", "tokens_revoked" => 2}
        })

      assert email.text_body =~ "Roadmap"
      assert email.text_body =~ "You were removed from this board. 2 API tokens were revoked."
      assert email.html_body =~ "You were removed from this board. 2 API tokens were revoked."
      assert email.text_body =~ "#{KanbanWeb.Endpoint.url()}/boards"
    end

    test "a target status notice names the target, its status and date", %{user: user} do
      email =
        build_email(user, %{
          event_type: :target_status_changed,
          title: "Q3 launch",
          url_path: "/targets/42",
          metadata: %{"status" => "missed", "target_date" => "2026-07-21"}
        })

      assert email.subject == "[Stride] Target status changed"
      assert email.text_body =~ "Q3 launch"
      assert email.text_body =~ "Missed its target date of 2026-07-21."
      assert email.html_body =~ "Missed its target date of 2026-07-21."
      assert email.text_body =~ "#{KanbanWeb.Endpoint.url()}/targets/42"
    end

    test "a board access notice is worded in the user's locale", %{user: user} do
      email =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          build_email(user, %{
            event_type: :board_access_changed,
            title: "Roadmap",
            url_path: "/boards",
            metadata: %{"change" => "removed", "tokens_revoked" => 2}
          })
        end)

      assert email.text_body =~
               "Sie wurden von diesem Board entfernt. 2 API-Tokens wurden widerrufen."
    end

    test "other notifications keep their board line", %{user: user} do
      board = board_fixture(user, %{name: "Roadmap"})

      assert build_email(user, %{board: board}).text_body =~ "Board: Roadmap"
    end

    test "HTML-escapes the title, actor and board name", %{user: user} do
      board = board_fixture(user, %{name: "<i>Board</i>"})

      email =
        user
        |> notification(%{
          title: "<script>alert(1)</script>",
          actor_name: "<b>x</b>",
          board: board
        })
        |> NotificationEmail.build(user)

      assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert email.html_body =~ "&lt;b&gt;x&lt;/b&gt;"
      assert email.html_body =~ "&lt;i&gt;Board&lt;/i&gt;"
      refute email.html_body =~ "<script>"
      refute email.html_body =~ "<b>x</b>"
      assert email.text_body =~ "<script>alert(1)</script>"
    end

    test "escapes free text in the body and keeps it out of the subject", %{user: user} do
      for {type, body} <- [
            task_reviewed: "Notes: <img src=x onerror=alert(1)>",
            task_unclaimed: "Reason: <a href=evil>"
          ] do
        email = build_email(user, %{event_type: type, body: body})

        assert email.html_body =~ Phoenix.HTML.html_escape(body) |> Phoenix.HTML.safe_to_string()
        refute email.html_body =~ body
        assert email.text_body =~ body
        refute email.subject =~ body
        refute email.subject =~ "Notes"
        refute email.subject =~ "Reason"
      end
    end

    test "escapes a quote in the url path inside the href", %{user: user} do
      email = build_email(user, %{url_path: ~s(/boards?x="y")})

      assert email.html_body =~ "/boards?x=&quot;y&quot;"
      refute email.html_body =~ ~s(x="y")
    end

    test "keeps a long unicode title out of the subject", %{user: user} do
      title = "é漢" |> String.duplicate(200) |> String.slice(0, 255)
      email = build_email(user, %{title: title})

      assert email.text_body =~ title
      assert email.html_body =~ title
      refute email.subject =~ title
    end

    test "carries one-click unsubscribe headers with a valid absolute link", %{user: user} do
      email = build_email(user, %{event_type: :task_assigned})
      url = unsubscribe_url(email)
      %URI{scheme: scheme, host: host, path: path, query: query} = URI.parse(url)

      assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"

      assert String.starts_with?(
               url,
               KanbanWeb.Endpoint.url() <> "/notifications/unsubscribe/one-click?"
             )

      assert scheme in ["http", "https"]
      assert is_binary(host)
      assert path == "/notifications/unsubscribe/one-click"

      %{"token" => token} = URI.decode_query(query)
      user_id = user.id

      assert {:ok, %{user_id: ^user_id, event_type: :task_assigned}} =
               UnsubscribeToken.verify(token)

      # The footer links to the confirmation page with the same token, not to
      # the one-click endpoint.
      confirm_url =
        KanbanWeb.Endpoint.url() <>
          "/notifications/unsubscribe?" <> URI.encode_query(%{"token" => token})

      assert email.text_body =~ confirm_url
      assert email.html_body =~ confirm_url
      refute email.text_body =~ "one-click"
      assert email.text_body =~ KanbanWeb.Endpoint.url() <> "/users/notifications"
    end

    test "keeps the token out of the URL path and redacted from logged params" do
      assert %{"token" => "[FILTERED]", "password" => "[FILTERED]", "page" => "2"} =
               Phoenix.Logger.filter_values(%{
                 "token" => "secret-token",
                 "password" => "secret",
                 "page" => "2"
               })
    end

    test "renders the after_goal exit code line from metadata, translated", %{user: user} do
      attrs = %{
        event_type: :after_goal_failed,
        metadata: %{"exit_code" => 3, "duration_ms" => 750}
      }

      email = build_email(user, attrs)
      assert email.text_body =~ "Exit code 3 after 750 ms"
      assert email.html_body =~ "Exit code 3 after 750 ms"

      short = build_email(user, %{attrs | metadata: %{"exit_code" => 3}})
      assert short.text_body =~ "Exit code 3"
      refute short.text_body =~ " ms"

      french =
        Gettext.with_locale(KanbanWeb.Gettext, "fr", fn -> build_email(user, attrs) end)

      refute french.text_body =~ "Exit code 3 after 750 ms"
      assert french.text_body =~ "750"
    end

    test "renders a review outcome and escaped notes, translated", %{user: user} do
      attrs = %{
        event_type: :task_reviewed,
        title: "W1: Ship it",
        actor_name: "Ada",
        body: "<script>x</script>",
        metadata: %{"outcome" => "changes_requested"}
      }

      email = build_email(user, attrs)
      assert email.subject == "[Stride] Your task was reviewed"
      assert email.text_body =~ "Changes requested"
      assert email.html_body =~ "Changes requested"
      assert email.html_body =~ "&lt;script&gt;x&lt;/script&gt;"
      refute email.html_body =~ "<script>"
      refute email.subject =~ "script"

      german = Gettext.with_locale(KanbanWeb.Gettext, "de", fn -> build_email(user, attrs) end)
      refute german.text_body =~ "Changes requested"
    end

    test "renders an unclaim reason after the Returned to Ready line", %{user: user} do
      email =
        build_email(user, %{event_type: :task_unclaimed, title: "W2: Hard", body: "Too big"})

      assert email.subject == "[Stride] Task unclaimed"
      assert email.text_body =~ ~r/Returned to Ready\. Reason:\s+Too big/
    end

    test "translates review and unclaim subjects in every supported locale", %{user: user} do
      for type <- [:task_reviewed, :task_unclaimed] do
        english = build_email(user, %{event_type: type})

        for locale <- ~w(de es fr ja pt zh) do
          email =
            Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
              build_email(user, %{event_type: type})
            end)

          refute email.subject == english.subject, "#{type} subject not translated for #{locale}"
        end
      end
    end

    test "uses a stable Message-ID per notification", %{user: user} do
      n = notification(user, %{})
      email = NotificationEmail.build(n, user)

      assert email.headers["Message-ID"] == "<notification-#{n.id}@stridelikeaboss.com>"
    end

    test "translates the subject and body in every supported locale", %{user: user} do
      english = build_email(user, %{})

      for locale <- ~w(de es fr ja pt zh) do
        email =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            build_email(user, %{})
          end)

        refute email.subject == english.subject, "subject not translated for #{locale}"
        refute email.text_body == english.text_body, "body not translated for #{locale}"
      end
    end
  end
end
