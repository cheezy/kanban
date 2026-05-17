defmodule KanbanWeb.MetricsKpiStripTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsKpiStrip.kpi_strip/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsKpiStrip

  defp render_strip(overrides) do
    base = %{
      cycle_time_median_minutes: 107,
      cycle_time_delta_pct: -12.0,
      lead_time_p75_minutes: 842,
      lead_time_delta_pct: -4.0,
      throughput_per_day: 23.6,
      throughput_delta_pct: 8.4,
      review_wait_minutes: 17,
      review_wait_delta_pct: -24.0
    }

    assigns = %{kpis: Map.merge(base, overrides)}

    rendered_to_string(~H"""
    <MetricsKpiStrip.kpi_strip kpis={@kpis} />
    """)
  end

  describe "kpi_strip/1 — markers and structure" do
    test "has the data-metrics-kpi-strip marker on the root" do
      assert render_strip(%{}) =~ "data-metrics-kpi-strip"
    end

    test "renders all four cell markers" do
      html = render_strip(%{})

      for marker <- ~w(cycle-time lead-time throughput review-wait) do
        assert html =~ ~s(data-metrics-kpi-cell="#{marker}")
      end
    end

    test "uses a 2-column mobile grid that expands to 4 columns at md+" do
      html = render_strip(%{})
      # Tailwind responsive class — 2-up on mobile, 4-up at md+.
      assert html =~ "grid grid-cols-2 md:grid-cols-4"
    end

    test "renders the four English labels" do
      html = render_strip(%{})
      assert html =~ "Cycle time · median"
      assert html =~ "Lead time · p75"
      assert html =~ "Throughput"
      assert html =~ "Wait time · Review"
    end
  end

  describe "kpi_strip/1 — value formatting" do
    test "formats minutes < 60 as 'Nm'" do
      html = render_strip(%{cycle_time_median_minutes: 47})

      cycle_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="cycle-time"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert cycle_cell =~ "47m"
      refute cycle_cell =~ "47h"
    end

    test "formats minutes spanning hours as 'Xh YYm'" do
      html = render_strip(%{cycle_time_median_minutes: 107})
      # 1h 47m — minutes padded to 2 digits
      assert html =~ "1h 47m"
    end

    test "formats clean hours as 'Nh' without trailing 0m" do
      html = render_strip(%{cycle_time_median_minutes: 120})

      cycle_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="cycle-time"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert cycle_cell =~ "2h"
      refute cycle_cell =~ "2h 00m"
    end

    test "formats zero minutes as '0m'" do
      html = render_strip(%{cycle_time_median_minutes: 0})
      assert html =~ "0m"
    end

    test "formats throughput as 'X.Y / day' with one decimal" do
      html = render_strip(%{throughput_per_day: 23.6})
      assert html =~ "23.6 / day"
    end

    test "formats zero throughput as '0 / day'" do
      html = render_strip(%{throughput_per_day: 0.0})
      assert html =~ "0 / day"
    end
  end

  describe "kpi_strip/1 — delta formatting and tone" do
    test "negative cycle-time delta renders in st-done (improving)" do
      html = render_strip(%{cycle_time_delta_pct: -12.0})

      cycle_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="cycle-time"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert cycle_cell =~ "-12.0%"
      assert cycle_cell =~ "color: var(--st-done)"
    end

    test "positive cycle-time delta renders in st-blocked (regressing)" do
      html = render_strip(%{cycle_time_delta_pct: 8.0})

      cycle_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="cycle-time"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert cycle_cell =~ "+8.0%"
      assert cycle_cell =~ "color: var(--st-blocked)"
    end

    test "positive throughput delta renders in st-done (improving)" do
      html = render_strip(%{throughput_delta_pct: 8.4})

      throughput_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="throughput"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert throughput_cell =~ "+8.4%"
      assert throughput_cell =~ "color: var(--st-done)"
    end

    test "negative throughput delta renders in st-blocked (regressing)" do
      html = render_strip(%{throughput_delta_pct: -3.5})

      throughput_cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="throughput"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert throughput_cell =~ "-3.5%"
      assert throughput_cell =~ "color: var(--st-blocked)"
    end

    test "negative review-wait delta renders in st-done (waits shrinking is good)" do
      html = render_strip(%{review_wait_delta_pct: -24.0})

      cell =
        Regex.run(~r/<div[^>]*data-metrics-kpi-cell="review-wait"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert cell =~ "color: var(--st-done)"
    end

    test "zero delta renders an em-dash in neutral tone" do
      html =
        render_strip(%{
          cycle_time_delta_pct: 0.0,
          lead_time_delta_pct: 0.0,
          throughput_delta_pct: 0.0,
          review_wait_delta_pct: 0.0
        })

      assert html =~ "—"
      assert html =~ "color: var(--ink-3)"
    end
  end

  describe "kpi_strip/1 — accessibility & tokens" do
    test "no hardcoded Tailwind greys leak into the markup" do
      html = render_strip(%{})
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
    end

    test "every visible label has a sub line" do
      html = render_strip(%{})
      assert length(Regex.scan(~r/data-metrics-kpi-sub/, html)) == 4
    end
  end
end
