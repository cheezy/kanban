defmodule KanbanWeb.MarketingDemoBandTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MarketingDemoBand

  test "links to the public demo board" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <MarketingDemoBand.marketing_demo_band />
      """)

    assert html =~ "data-demo-band"
    assert html =~ ~s(href="/demo")
    assert html =~ "Watch the live demo"
    assert html =~ "See agents work a board"
  end

  test "renders translated under fr" do
    assigns = %{}

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        rendered_to_string(~H"""
        <MarketingDemoBand.marketing_demo_band />
        """)
      end)

    refute html =~ "Watch the live demo"
    assert html =~ ~s(href="/demo")
  end
end
