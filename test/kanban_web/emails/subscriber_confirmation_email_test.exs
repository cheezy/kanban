defmodule KanbanWeb.Emails.SubscriberConfirmationEmailTest do
  use ExUnit.Case, async: true

  alias Kanban.Subscribers.Subscriber
  alias KanbanWeb.Emails.SubscriberConfirmationEmail

  @subscriber %Subscriber{id: 7, email: "release@example.test", locale: "en"}
  @confirm "confirm-token_1"
  @unsubscribe "unsubscribe-token_2"

  # Every English string the email renders, so a locale that falls back to
  # English for any of them fails below.
  @english_labels [
    "Confirm your subscription to Stride release announcements",
    "Confirm your subscription",
    "Someone asked to receive Stride release announcements",
    "Confirm subscription",
    "This link expires in 7 days",
    "You are receiving this email because this address was entered",
    "Unsubscribe"
  ]

  defp build, do: SubscriberConfirmationEmail.build(@subscriber, @confirm, @unsubscribe)

  test "addresses the subscriber from the shared sender with a unique Message-ID" do
    email = build()

    assert email.to == [{"", "release@example.test"}]
    assert email.from == {"Stride Support", "noreply@stridelikeaboss.com"}
    assert email.subject == "[Stride] Confirm your subscription to Stride release announcements"
    assert email.headers["Message-ID"] =~ ~r/^<release-signup-7-\d+@stridelikeaboss\.com>$/
    refute build().headers["Message-ID"] == email.headers["Message-ID"]
  end

  test "links the confirm page and an unsubscribe page in both bodies" do
    email = build()
    base = KanbanWeb.Endpoint.url()
    confirm = base <> "/releases/confirm?token=" <> @confirm
    unsubscribe = base <> "/releases/unsubscribe?token=" <> @unsubscribe

    for url <- [confirm, unsubscribe] do
      assert email.html_body =~ ~s(href="#{url}")
      assert email.text_body =~ url
    end
  end

  test "carries the RFC 8058 one-click List-Unsubscribe headers" do
    email = build()

    assert email.headers["List-Unsubscribe"] ==
             "<#{KanbanWeb.Endpoint.url()}/releases/unsubscribe/one-click?token=#{@unsubscribe}>"

    assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
  end

  test "the one-click List-Unsubscribe URL carries a non-English locale, so a browser opening it gets the email's language" do
    email = Gettext.with_locale(KanbanWeb.Gettext, "de", &build/0)

    assert email.headers["List-Unsubscribe"] ==
             "<#{KanbanWeb.Endpoint.url()}/releases/unsubscribe/one-click?token=#{@unsubscribe}&locale=de>"
  end

  test "HTML-escapes the hrefs in the HTML body and leaves the text body plain" do
    email = Gettext.with_locale(KanbanWeb.Gettext, "de", &build/0)

    assert email.html_body =~
             ~s(href="#{KanbanWeb.Endpoint.url()}/releases/confirm?token=#{@confirm}&amp;locale=de")

    refute email.html_body =~ "&locale=de"
    assert email.text_body =~ "?token=#{@confirm}&locale=de"
  end

  test "renders in the calling locale with a ?locale= on each page link" do
    for locale <- ~w(de es fr ja pt zh) do
      email = Gettext.with_locale(KanbanWeb.Gettext, locale, &build/0)

      for label <- @english_labels do
        refute email.text_body =~ label, "#{locale} falls back to English for #{inspect(label)}"
        refute email.subject =~ label
      end

      assert email.text_body =~ "/releases/confirm?token=#{@confirm}&locale=#{locale}"
      assert email.text_body =~ "/releases/unsubscribe?token=#{@unsubscribe}&locale=#{locale}"
      assert email.headers["List-Unsubscribe"] =~ "?token=#{@unsubscribe}&locale=#{locale}>"
    end
  end
end
