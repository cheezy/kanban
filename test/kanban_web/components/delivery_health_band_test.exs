defmodule KanbanWeb.DeliveryHealthBandTest do
  @moduledoc """
  Unit tests for the `KanbanWeb.DeliveryHealthBand` function component. The
  band is fed hand-built rollup maps (the `:targets` shape returned by
  `Kanban.Targets.DeliveryRollup.build/2`) so it exercises no database.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.DeliveryHealthBand

  defp render_band(targets) do
    assigns = %{targets: targets}

    rendered_to_string(~H"""
    <DeliveryHealthBand.delivery_health_band targets={@targets} />
    """)
  end

  # A minimal rollup entry: only :status and :target.target_date are read.
  defp entry(status, %Date{} = date) do
    %{status: status, target: %{target_date: date}}
  end

  # The <dd> count for a bucket marker, as an integer.
  defp stat_count(html, marker) do
    [_, count] =
      Regex.run(
        ~r/data-delivery-health-stat="#{marker}".*?<dd[^>]*>\s*(\d+)\s*<\/dd>/s,
        html
      )

    String.to_integer(count)
  end

  describe "delivery_health_band/1 with targets" do
    test "renders the band heading and one bucket per status" do
      html =
        render_band([
          entry(:on_track, ~D[2026-08-01]),
          entry(:on_track, ~D[2026-07-15]),
          entry(:at_risk, ~D[2026-07-20]),
          entry(:complete, ~D[2026-06-01])
        ])

      assert html =~ "data-delivery-health-band"
      # The band's vertical padding lives on .agents-health-band so a
      # compression pass can target it from a media query.
      assert html =~ ~s(class="stride-screen agents-health-band")
      assert html =~ "Delivery health"

      for marker <- ~w(on-track at-risk missed complete) do
        assert html =~ ~s(data-delivery-health-stat="#{marker}")
      end

      assert html =~ "On-track"
      assert html =~ "At-risk"
      assert html =~ "Missed"
      assert html =~ "Complete"
    end

    test "renders the correct count per bucket" do
      html =
        render_band([
          entry(:on_track, ~D[2026-08-01]),
          entry(:on_track, ~D[2026-07-15]),
          entry(:at_risk, ~D[2026-07-20]),
          entry(:complete, ~D[2026-06-01])
        ])

      assert stat_count(html, "on-track") == 2
      assert stat_count(html, "at-risk") == 1
      assert stat_count(html, "missed") == 0
      assert stat_count(html, "complete") == 1
    end

    test "shows the soonest target date for a populated bucket and an em dash for an empty one" do
      html =
        render_band([
          entry(:on_track, ~D[2026-08-01]),
          entry(:on_track, ~D[2026-07-15])
        ])

      # Soonest of the two on-track targets is Jul 15.
      assert html =~ "Jul 15, 2026"
      refute html =~ "Aug 1, 2026"
      # Empty buckets (at-risk/missed/complete) show an em dash.
      assert html =~ "—"
    end

    test "uses dark-mode-safe status tokens, not hardcoded colors" do
      html = render_band([entry(:on_track, ~D[2026-08-01])])

      assert html =~ "var(--st-ready)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-blocked)"
      assert html =~ "var(--st-done)"
      refute html =~ "text-gray-"
      refute html =~ "bg-white"
      refute html =~ "#fff"
    end
  end

  describe "delivery_health_band/1 with no targets" do
    test "renders an empty state without error" do
      html = render_band([])

      assert html =~ "data-delivery-health-band"
      assert html =~ "Delivery health"
      assert html =~ "data-delivery-health-empty"
      assert html =~ "No delivery targets yet."
      refute html =~ "data-delivery-health-stats"
    end
  end
end
