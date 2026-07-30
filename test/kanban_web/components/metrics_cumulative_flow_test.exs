defmodule KanbanWeb.MetricsCumulativeFlowTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsCumulativeFlow.cumulative_flow/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsCumulativeFlow

  defp snapshots(opts \\ []) do
    base = ~D[2026-05-01]

    backlog = Keyword.get(opts, :backlog, 20)
    ready = Keyword.get(opts, :ready, 5)
    doing = Keyword.get(opts, :doing, 6)
    review = Keyword.get(opts, :review, 3)
    done = Keyword.get(opts, :done, 40)

    for i <- 0..13 do
      %{
        date: Date.add(base, i),
        backlog: backlog,
        ready: ready,
        doing: doing,
        review: review,
        done: done + i
      }
    end
  end

  defp render_chart(snapshots) do
    assigns = %{snapshots: snapshots}

    rendered_to_string(~H"""
    <MetricsCumulativeFlow.cumulative_flow snapshots={@snapshots} />
    """)
  end

  # Separate arity rather than a default argument, so the arity-1 clause above
  # keeps exercising the "attr omitted" path the show_done default guards.
  defp render_chart(snapshots, show_done) when is_boolean(show_done) do
    assigns = %{snapshots: snapshots, show_done: show_done}

    rendered_to_string(~H"""
    <MetricsCumulativeFlow.cumulative_flow snapshots={@snapshots} show_done={@show_done} />
    """)
  end

  defp layer_path(html, name) do
    ~r/data-metrics-cumulative-flow-layer="#{name}"\s+d="([^"]+)"/
    |> Regex.run(html, capture: :all_but_first)
    |> hd()
  end

  describe "cumulative_flow/1 — markers and structure" do
    test "renders the root marker" do
      assert render_chart(snapshots()) =~ "data-metrics-cumulative-flow"
    end

    test "renders the responsive 800x200 SVG" do
      html = render_chart(snapshots())
      assert html =~ "viewBox=\"0 0 800 200\""
      assert html =~ "preserveAspectRatio=\"none\""
      assert html =~ "height: 200px"
    end

    test "renders one <path> per layer with the data attribute" do
      html = render_chart(snapshots())

      for name <- ~w(done review doing ready backlog) do
        assert html =~ ~s(data-metrics-cumulative-flow-layer="#{name}")
      end

      assert length(Regex.scan(~r/data-metrics-cumulative-flow-layer/, html)) == 5
    end
  end

  describe "cumulative_flow/1 — colors and legend" do
    test "each layer is tinted with its status token" do
      html = render_chart(snapshots())

      assert html =~ "var(--st-done)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-ready)"
      assert html =~ "var(--st-backlog)"
    end

    test "layers use 0.8 fill-opacity" do
      assert render_chart(snapshots()) =~ ~s(fill-opacity="0.8")
    end

    test "renders the five legend swatches with translated labels" do
      html = render_chart(snapshots())

      for label <- ~w(Backlog Ready Doing Review Done) do
        assert html =~ label
      end
    end

    test "no hardcoded Tailwind greys or daisyUI base colors" do
      html = render_chart(snapshots())
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
    end
  end

  describe "cumulative_flow/1 — y-axis scale" do
    test "renders the peak stacked total as a gridline" do
      # Default snapshot peak (last day): 20 + 5 + 6 + 3 + (40 + 13) = 87.
      assert render_chart(snapshots()) =~ ~s(data-metrics-cumulative-flow-gridline="87")
    end

    test "derives intermediate ticks and a zero baseline from the peak" do
      html = render_chart(snapshots())

      # peak 87 -> [87, round(58), round(29), 0]
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="58")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="29")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-gridline/, html)) == 4
    end

    test "an empty snapshot list renders without error and still shows a scale" do
      html = render_chart([])

      assert html =~ "data-metrics-cumulative-flow"
      # peak guards to 1 -> ticks collapse to [1, 0].
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="1")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
    end

    test "a peak total of one renders a 1-and-0 scale" do
      single = [%{date: ~D[2026-05-01], backlog: 1, ready: 0, doing: 0, review: 0, done: 0}]
      html = render_chart(single)

      assert html =~ ~s(data-metrics-cumulative-flow-gridline="1")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-gridline/, html)) == 2
    end

    test "gridlines use tabular-nums and theme tokens" do
      html = render_chart(snapshots())

      assert html =~ "font-variant-numeric: tabular-nums"
      assert html =~ "var(--ink-4)"
      assert html =~ "var(--line-2)"
      refute html =~ "text-gray-"
    end
  end

  describe "cumulative_flow/1 — show_done attr" do
    test "show_done={true} renders markup identical to omitting the attr" do
      assert render_chart(snapshots(), true) == render_chart(snapshots())
    end

    test "show_done={false} renders only the four non-done layers" do
      html = render_chart(snapshots(), false)

      refute html =~ ~s(data-metrics-cumulative-flow-layer="done")

      for name <- ~w(review doing ready backlog) do
        assert html =~ ~s(data-metrics-cumulative-flow-layer="#{name}")
      end

      assert length(Regex.scan(~r/data-metrics-cumulative-flow-layer/, html)) == 4
    end

    test "show_done={false} omits the Done legend swatch and keeps the other four" do
      html = render_chart(snapshots(), false)

      # The only capital-D "Done" in the template is that label, and the done
      # layer's fill is the only other emitter of the token.
      refute html =~ "Done"
      refute html =~ "var(--st-done)"

      for label <- ~w(Backlog Ready Doing Review) do
        assert html =~ label
      end

      for token <- ~w(--st-backlog --st-ready --st-doing --st-review) do
        assert html =~ "var(#{token})"
      end
    end

    test "show_done={false} emits only theme tokens, never a hardcoded color" do
      html = render_chart(snapshots(), false)

      # Dark mode is satisfied by construction: the four-band branch introduces
      # no new color, only theme tokens that already adapt per theme.
      for token <- ~w(--surface --line --ink --ink-3 --ink-4 --line-2) do
        assert html =~ "var(#{token})"
      end

      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
      refute html =~ ~r/#[0-9a-fA-F]{3,6}\b/
    end

    test "show_done={false} re-bases the surviving bands onto the zero baseline" do
      layers =
        snapshots()
        |> MetricsCumulativeFlow.build_layers()
        |> MetricsCumulativeFlow.exclude_done_layer()

      assert Enum.map(layers, & &1.name) == [:review, :doing, :ready, :backlog]

      [review | _] = layers
      assert review.bottom == List.duplicate(0, 14)
      # Thickness preserved: review is 3/day in the fixture.
      assert review.top == List.duplicate(3, 14)
      # Four-band total: 20 + 5 + 6 + 3.
      assert List.last(layers).top == List.duplicate(34, 14)

      layers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [lower, upper] -> assert upper.bottom == lower.top end)
    end

    test "exclude_done_layer/1 returns an empty list for an empty input" do
      assert MetricsCumulativeFlow.exclude_done_layer([]) == []
    end

    test "the re-based bottom band actually sits on the plot floor" do
      # Four-band peak 34 -> review's top row projects to 200 - 3/34*180.
      path = layer_path(render_chart(snapshots(), false), "review")
      assert String.starts_with?(path, "M0.0,184.12")
      assert String.ends_with?(path, "L0.0,200.0 Z")

      # With done shown, peak 87 and review's top row is 43 -> 200 - 43/87*180.
      shown = layer_path(render_chart(snapshots()), "review")
      assert String.starts_with?(shown, "M0.0,111.03")
    end

    test "show_done={false} recomputes the gridlines from the four-band peak" do
      # done dwarfs the rest: five-band peak 34 + 1013 = 1047, four-band peak 34.
      html = render_chart(snapshots(done: 1000), false)

      # peak 34 -> [34, round(22.67), round(11.33), 0]
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="34")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="23")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="11")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-gridline/, html)) == 4

      refute html =~ ~s(data-metrics-cumulative-flow-gridline="1047")
      refute render_chart(snapshots(), false) =~ ~s(data-metrics-cumulative-flow-gridline="87")
    end

    test "the four-band peak is the window maximum, not the last day's total" do
      # Non-done work peaks on day 2, when done is zero.
      snaps = [
        %{date: ~D[2026-05-01], backlog: 5, ready: 0, doing: 0, review: 0, done: 500},
        %{date: ~D[2026-05-02], backlog: 30, ready: 0, doing: 0, review: 0, done: 0}
      ]

      html = render_chart(snaps, false)

      # peak 30 -> [30, 20, 10, 0]. The five-band peak would be 505.
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="30")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="20")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="10")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-gridline/, html)) == 4
      refute html =~ ~s(data-metrics-cumulative-flow-gridline="505")
    end

    test "an all-zero non-done stack renders without dividing by zero" do
      zeros = snapshots(backlog: 0, ready: 0, doing: 0, review: 0)
      html = render_chart(zeros, false)

      assert html =~ "data-metrics-cumulative-flow"
      # peak floors to 1 -> ticks collapse to [1, 0].
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="1")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-gridline/, html)) == 2

      refute html =~ ~s(data-metrics-cumulative-flow-layer="done")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-layer/, html)) == 4

      # The same fixture still renders with the done band shown.
      assert render_chart(zeros) =~ "data-metrics-cumulative-flow"
    end

    test "a single-day window renders with show_done={false}" do
      single = [%{date: ~D[2026-05-01], backlog: 4, ready: 0, doing: 0, review: 0, done: 900}]
      html = render_chart(single, false)

      # days - 1 == 0, so step_x falls back to the max(days - 1, 1) guard.
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="4")
      refute html =~ ~s(data-metrics-cumulative-flow-gridline="904")
      assert length(Regex.scan(~r/data-metrics-cumulative-flow-layer/, html)) == 4
    end

    test "a snapshot missing the :done key renders with show_done={false}" do
      partial = [%{date: ~D[2026-05-01], doing: 10}]

      layers =
        partial
        |> MetricsCumulativeFlow.build_layers()
        |> MetricsCumulativeFlow.exclude_done_layer()

      # Map.get/3 defaults :done to 0, so re-basing subtracts a zero vector.
      assert Enum.map(layers, & &1.name) == [:review, :doing, :ready, :backlog]
      assert hd(layers).bottom == [0]
      assert Enum.find(layers, &(&1.name == :doing)).top == [10]

      assert render_chart(partial, false) =~ ~s(data-metrics-cumulative-flow-gridline="10")
    end

    test "an empty snapshot list renders with show_done={false}" do
      html = render_chart([], false)

      assert html =~ "data-metrics-cumulative-flow"
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="1")
      assert html =~ ~s(data-metrics-cumulative-flow-gridline="0")
      assert Regex.scan(~r/data-metrics-cumulative-flow-layer/, html) == []
      refute html =~ "var(--st-done)"
    end
  end

  describe "build_layers/1 — stacking math" do
    test "returns an empty list for an empty input" do
      assert MetricsCumulativeFlow.build_layers([]) == []
    end

    test "returns 5 layers in bottom-to-top order matching the design source" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())
      assert Enum.map(layers, & &1.name) == [:done, :review, :doing, :ready, :backlog]
    end

    test "each layer's :bottom equals the previous layer's :top (stacking)" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())

      layers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [lower, upper] ->
        assert upper.bottom == lower.top
      end)
    end

    test "the bottom-most layer (:done) starts from a zero bottom row" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())
      [%{name: :done, bottom: bottom} | _] = layers
      assert bottom == List.duplicate(0, 14)
    end

    test "the topmost layer's :top equals the per-day sum of all five buckets" do
      snaps = snapshots(backlog: 1, ready: 2, doing: 3, review: 4, done: 5)
      layers = MetricsCumulativeFlow.build_layers(snaps)
      top = List.last(layers).top

      expected =
        snaps
        |> Enum.map(fn s -> s.backlog + s.ready + s.doing + s.review + s.done end)

      assert top == expected
    end

    test "the one-argument call still returns all five layers so the PDF export is unaffected" do
      layers = MetricsCumulativeFlow.build_layers(snapshots())

      assert Enum.map(layers, & &1.name) == [:done, :review, :doing, :ready, :backlog]
      assert length(layers) == 5
      # Untouched by the show_done filter: the :done band is still present and
      # still based at zero, which is what flow_chart_geometry/3 consumes.
      [%{name: :done, bottom: bottom} | _] = layers
      assert bottom == List.duplicate(0, 14)
    end

    test "handles missing keys by treating them as zero" do
      partial = [%{date: ~D[2026-05-01], doing: 10}]
      [done, _, doing, _, _] = MetricsCumulativeFlow.build_layers(partial)
      assert done.top == [0]
      assert doing.top == [10]
    end
  end
end
