defmodule KanbanWeb.Emails.DigestEmailTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias KanbanWeb.Emails.DigestEmail
  alias KanbanWeb.UnsubscribeToken

  @user %User{id: 31, email: "digest@example.com"}
  @week "2026-W45"

  defp digest(overrides) do
    Map.merge(
      %{
        window_start: ~D[2026-10-27],
        window_end: ~D[2026-11-02],
        boards: [
          %{
            id: 5,
            name: "Main board",
            open: 4,
            doing: 2,
            review: 1,
            done_this_week: 6,
            goals_completed: 1
          }
        ],
        more_boards: 0,
        tasks_done: 6,
        goals_completed: 1,
        reviews: %{
          count: 2,
          oldest_age_hours: 50,
          oldest: [
            %{
              identifier: "W12",
              title: "Fix login",
              board_id: 5,
              board_name: "Main board",
              age_hours: 50
            },
            %{
              identifier: "W13",
              title: "Add search",
              board_id: 5,
              board_name: "Main board",
              age_hours: 3
            }
          ]
        }
      },
      overrides
    )
  end

  defp build(overrides \\ %{}), do: DigestEmail.build(@user, digest(overrides), @week)

  defp base, do: KanbanWeb.Endpoint.url()

  test "addresses the user with a fixed subject and both bodies" do
    email = build()

    assert email.to == [{"", "digest@example.com"}]
    assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
    assert email.subject == "[Stride] Your weekly digest"

    for body <- [email.html_body, email.text_body] do
      assert body =~ "Summary for 2026-10-27 – 2026-11-02 (UTC)"
      assert body =~ "Tasks done: 6"
      assert body =~ "Goals completed: 1"
      assert body =~ "Waiting for review: 2"
      assert body =~ "Main board"
      assert body =~ "Fix login"
      assert body =~ "W12 on Main board, waiting 2 d"
      assert body =~ "W13 on Main board, waiting 3 h"
    end
  end

  test "links each board, the review queue and the preferences page" do
    email = build()

    assert email.html_body =~ ~s(href="#{base()}/boards/5")
    assert email.html_body =~ ~s(href="#{base()}/review")
    assert email.html_body =~ ~s(href="#{base()}/users/notifications")
    assert email.text_body =~ "#{base()}/boards/5"
    assert email.text_body =~ "Open the review queue: #{base()}/review"
  end

  test "HTML-escapes board names, task titles and identifiers" do
    email =
      build(%{
        boards: [
          %{
            id: 9,
            name: "<b>Board</b>",
            open: 0,
            doing: 0,
            review: 0,
            done_this_week: 1,
            goals_completed: 0
          }
        ],
        reviews: %{
          count: 1,
          oldest_age_hours: 1,
          oldest: [
            %{
              identifier: "<i>W1</i>",
              title: "<script>alert(1)</script>",
              board_id: 9,
              board_name: "<b>Board</b>",
              age_hours: 1
            }
          ]
        }
      })

    assert email.html_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert email.html_body =~ "&lt;b&gt;Board&lt;/b&gt;"
    assert email.html_body =~ "&lt;i&gt;W1&lt;/i&gt;"
    refute email.html_body =~ "<script>"
    refute email.html_body =~ "<b>Board</b>"
    refute email.html_body =~ "<i>W1</i>"
    assert email.text_body =~ "<script>alert(1)</script>"
    refute email.subject =~ "Board"
  end

  test "carries one-click unsubscribe headers for the weekly digest" do
    email = build()

    assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    assert [_, url] = Regex.run(~r/\A<(.+)>\z/, email.headers["List-Unsubscribe"])

    assert String.starts_with?(url, base() <> "/notifications/unsubscribe/one-click?token=")

    token = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")
    assert {:ok, %{user_id: 31, event_type: :weekly_digest}} = UnsubscribeToken.verify(token)

    assert email.html_body =~ ~s(href="#{base()}/notifications/unsubscribe?token=)
  end

  test "uses a Message-ID that is stable per user and week" do
    assert build().headers["Message-ID"] == "<weekly-digest-31-2026-W45@stridelikeaboss.com>"
  end

  test "says when nothing is waiting for review" do
    email = build(%{reviews: %{count: 0, oldest_age_hours: nil, oldest: []}})

    for body <- [email.html_body, email.text_body] do
      assert body =~ "Nothing is waiting for review."
      refute body =~ "Oldest pending reviews"
    end

    assert email.html_body =~ ~s(href="#{base()}/review")
  end

  test "counts the boards it leaves out" do
    email = build(%{more_boards: 3})

    assert email.html_body =~ "Other boards: 3"
    assert email.text_body =~ "Other boards: 3"
    refute build().html_body =~ "Other boards"
  end

  test "renders in every supported locale" do
    english = build()

    for locale <- ~w(de es fr ja pt zh) do
      email = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> build() end)

      refute email.subject == english.subject, "subject not translated for #{locale}"

      for label <- ["Tasks done", "Your boards", "Oldest pending reviews", "Summary for"] do
        refute email.html_body =~ label, "#{label} not translated for #{locale}"
      end
    end
  end
end
