defmodule KanbanWeb.MarketingHitmeBandTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MarketingHitmeBand

  test "promotes the half-day session and links to /HitMe" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <MarketingHitmeBand.marketing_hitme_band />
      """)

    assert html =~ "data-hitme-band"
    assert html =~ ~s(href="/HitMe")
    assert html =~ "Half-day AI proof-of-concept sessions"
    assert html =~ "Book a half-day session"
    assert html =~ ~s(src="/images/marketing/hitme-sticker.png")
    assert html =~ ~s(width="504")
  end

  for {locale, booking} <- [{"de", "Halbtägige Session buchen"}, {"ja", "半日セッションを予約する"}] do
    test "renders translated under #{locale}" do
      assigns = %{}

      html =
        Gettext.with_locale(KanbanWeb.Gettext, unquote(locale), fn ->
          rendered_to_string(~H"""
          <MarketingHitmeBand.marketing_hitme_band />
          """)
        end)

      assert html =~ unquote(booking)
      refute html =~ "Book a half-day session"
      refute html =~ "In half a day"
      assert html =~ ~s(href="/HitMe")
    end
  end

  test "renders translated under fr" do
    assigns = %{}

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        rendered_to_string(~H"""
        <MarketingHitmeBand.marketing_hitme_band />
        """)
      end)

    refute html =~ "Book a half-day session"
    refute html =~ "Half-day AI proof-of-concept sessions"
    assert html =~ ~s(href="/HitMe")
  end
end
