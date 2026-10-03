defmodule KanbanWeb.Emails.EmailHelpersTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Emails.EmailHelpers
  alias KanbanWeb.UnsubscribeToken

  defp token(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("token")
  end

  test "from/0 is the Stride support sender" do
    assert EmailHelpers.from() == {"Stride Support", "noreply@stridelikeaboss.com"}
  end

  test "button_style/0 is an inline style string" do
    assert EmailHelpers.button_style() =~ "display:inline-block"
  end

  test "escape/1 HTML-escapes markup and quotes" do
    assert EmailHelpers.escape(~s(<a href="x">&</a>)) ==
             "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;"
  end

  describe "unsubscribe_urls/2" do
    test "signs both unsubscribe links for the user and event type" do
      urls = EmailHelpers.unsubscribe_urls(42, :weekly_digest)
      base = KanbanWeb.Endpoint.url()

      assert String.starts_with?(urls.unsubscribe, base <> "/notifications/unsubscribe?token=")

      assert String.starts_with?(
               urls.one_click,
               base <> "/notifications/unsubscribe/one-click?token="
             )

      assert urls.preferences == base <> "/users/notifications"

      for url <- [urls.unsubscribe, urls.one_click] do
        assert {:ok, %{user_id: 42, event_type: :weekly_digest}} =
                 url |> token() |> UnsubscribeToken.verify()
      end
    end
  end

  test "put_unsubscribe_headers/2 adds the RFC 8058 headers" do
    urls = EmailHelpers.unsubscribe_urls(7, :task_assigned)
    email = EmailHelpers.put_unsubscribe_headers(Swoosh.Email.new(), urls)

    assert email.headers["List-Unsubscribe"] == "<" <> urls.one_click <> ">"
    assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
  end

  describe "footers" do
    setup do
      %{urls: %{unsubscribe: ~s(/u?token="a"), one_click: "/o", preferences: "/p"}}
    end

    test "footer_html/1 links unsubscribe and preferences with escaped hrefs", %{urls: urls} do
      html = EmailHelpers.footer_html(urls)

      assert html =~ ~s(href="/u?token=&quot;a&quot;")
      assert html =~ ~s(href="/p")
      assert html =~ "Unsubscribe from these emails"
      assert html =~ "Manage notification preferences"
    end

    test "footer_text_lines/1 lists the notice and both links", %{urls: urls} do
      assert ["--", notice, unsubscribe, preferences] = EmailHelpers.footer_text_lines(urls)
      assert notice =~ "You are receiving this"
      assert unsubscribe == ~s(Unsubscribe from these emails: /u?token="a")
      assert preferences == "Manage notification preferences: /p"
    end
  end
end
